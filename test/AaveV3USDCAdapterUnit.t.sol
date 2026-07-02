// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3USDCAdapter} from "../src/adapters/AaveV3USDCAdapter.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

/// @dev Minimal Aave V3 Pool stub: the adapter constructor only needs
///      getReserveData(asset).aTokenAddress to check against the aToken_
///      passed in. Not a fork -- no supply/withdraw logic needed for these
///      unit tests (constructor/harvest/rescue only).
contract MockAavePool {
    address public reserveAToken;

    function setReserveAToken(address aToken_) external {
        reserveAToken = aToken_;
    }

    function getReserveData(address) external view returns (IAavePool.ReserveData memory data) {
        data.aTokenAddress = reserveAToken;
    }
}

/// @title AaveV3USDCAdapterUnitTest
/// @notice Non-fork unit tests for the 3 audit-hardening fixes:
///         L-5 (constructor asset/pool/aToken binding), harvest onlyVault
///         gating, and ADP-2 rescueToken. No RPC required.
contract AaveV3USDCAdapterUnitTest is Test {
    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address stranger   = makeAddr("stranger");
    address recipient  = makeAddr("recipient");

    MockUSDC     usdc;
    MockUSDC     aToken; // stand-in ERC20 used as the "aUSDC" position token
    MockAavePool pool;
    AaveV3USDCAdapter adapter;

    function setUp() public {
        usdc   = new MockUSDC();
        aToken = new MockUSDC();
        pool   = new MockAavePool();
        pool.setReserveAToken(address(aToken));

        adapter = new AaveV3USDCAdapter(
            address(usdc),
            address(pool),
            address(aToken),
            vault,
            governance,
            0
        );
    }

    // ─────────────────────────────────────────────────────────
    // Fix 1 — L-5: constructor binds asset↔pool↔aToken
    // ─────────────────────────────────────────────────────────

    function test_constructor_reverts_on_atoken_pool_mismatch() public {
        MockAavePool badPool = new MockAavePool();
        MockUSDC wrongAToken = new MockUSDC();
        badPool.setReserveAToken(address(wrongAToken)); // != aToken passed below

        vm.expectRevert("ADAPTER: aToken/pool mismatch");
        new AaveV3USDCAdapter(
            address(usdc),
            address(badPool),
            address(aToken), // mismatched vs. badPool's registered aToken
            vault,
            governance,
            0
        );
    }

    function test_constructor_succeeds_when_atoken_matches() public view {
        assertEq(address(adapter.aToken()), address(aToken));
    }

    // ─────────────────────────────────────────────────────────
    // Fix 2 — harvest access control
    // ─────────────────────────────────────────────────────────

    function test_harvest_only_vault() public {
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.harvest();
    }

    function test_harvest_succeeds_for_vault() public {
        vm.prank(vault);
        uint256 harvested = adapter.harvest();
        assertEq(harvested, 0);
    }

    // ─────────────────────────────────────────────────────────
    // Fix 3 — ADP-2: rescueToken
    // ─────────────────────────────────────────────────────────

    function test_rescue_sweeps_stray_token() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(adapter), 1_000e6);

        vm.prank(governance);
        uint256 amount = adapter.rescueToken(address(stray), recipient);

        assertEq(amount, 1_000e6);
        assertEq(stray.balanceOf(recipient), 1_000e6);
        assertEq(stray.balanceOf(address(adapter)), 0);
    }

    function test_rescue_cannot_take_position_token() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: cannot rescue position");
        adapter.rescueToken(address(aToken), recipient);
    }

    function test_rescue_only_governance() public {
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.rescueToken(address(usdc), recipient);
    }
}
