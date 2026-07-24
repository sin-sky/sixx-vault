// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISIXXVault} from "../src/interfaces/ISIXXVault.sol";

/// @dev Minimal mock ERC-20 (18 decimals, mirrors a WBNB-style asset for the cap tests).
contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice 3-C: on-chain deposit cap unit tests. Verifies the cap bounds TVL via
///         maxDeposit/maxMint, is governance-gated, defaults to unlimited (backward
///         compatible), and never blocks withdrawals (ADR-007 liveness preserved).
contract SIXXVaultDepositCapTest is Test {
    address governance = address(0xBEEF);
    address alice      = address(0xA11CE);
    address bob        = address(0xB0B);
    address feeRcpt    = address(0xFEE);
    address guardianAddr = address(0x6042D);

    MockWBNB        wbnb;
    AdapterRegistry registry;
    SIXXVault       vault;
    MockAdapter     adapter;

    uint256 constant ONE = 1e18;

    event DepositCapUpdated(uint256 oldCap, uint256 newCap);

    function setUp() public {
        wbnb = new MockWBNB();

        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(wbnb)),
            "SIXX BNB Yield",
            "sxWBNB",
            governance,
            address(registry),
            feeRcpt,
            guardianAddr
        );

        adapter = new MockAdapter(address(wbnb), address(vault));

        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Mock");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        wbnb.mint(alice, 1_000 * ONE);
        wbnb.mint(bob,   1_000 * ONE);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        wbnb.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    // ─── Defaults / backward compatibility ────────────────────

    function test_depositCap_defaultsToUnlimited() public view {
        assertEq(vault.depositCap(), type(uint256).max);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    // ─── Governance gating ────────────────────────────────────

    function test_setDepositCap_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setDepositCap(100 * ONE);
    }

    function test_setDepositCap_emitsEventAndUpdates() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit DepositCapUpdated(type(uint256).max, 500 * ONE);
        vm.prank(governance);
        vault.setDepositCap(500 * ONE);
        assertEq(vault.depositCap(), 500 * ONE);
    }

    // ─── maxDeposit / maxMint reflect the cap ─────────────────

    function test_maxDeposit_reflectsCapMinusTotalAssets() public {
        vm.prank(governance);
        vault.setDepositCap(100 * ONE);

        assertEq(vault.maxDeposit(alice), 100 * ONE);

        _deposit(alice, 40 * ONE);
        assertEq(vault.totalAssets(), 40 * ONE);
        assertEq(vault.maxDeposit(alice), 60 * ONE);
    }

    function test_maxMint_reflectsCapHeadroom() public {
        vm.prank(governance);
        vault.setDepositCap(100 * ONE);
        // Fresh 1:1 vault: headroom in shares == previewDeposit(headroom in assets).
        assertEq(vault.maxMint(alice), vault.previewDeposit(100 * ONE));

        _deposit(alice, 40 * ONE);
        assertEq(vault.maxMint(alice), vault.previewDeposit(60 * ONE));
    }

    // ─── Enforcement: deposit blocked over cap, resumes when raised ───

    function test_deposit_atCap_succeeds_overCap_reverts() public {
        vm.prank(governance);
        vault.setDepositCap(100 * ONE);

        _deposit(alice, 100 * ONE); // exactly at cap
        assertEq(vault.totalAssets(), 100 * ONE);
        assertEq(vault.maxDeposit(bob), 0);

        vm.startPrank(bob);
        wbnb.approve(address(vault), 1 * ONE);
        vm.expectRevert(); // OZ ERC4626ExceededMaxDeposit
        vault.deposit(1 * ONE, bob);
        vm.stopPrank();
    }

    function test_deposit_resumesAfterCapRaised() public {
        vm.prank(governance);
        vault.setDepositCap(50 * ONE);
        _deposit(alice, 50 * ONE);
        assertEq(vault.maxDeposit(bob), 0);

        vm.prank(governance);
        vault.setDepositCap(120 * ONE);
        assertEq(vault.maxDeposit(bob), 70 * ONE);
        _deposit(bob, 70 * ONE); // now allowed
        assertEq(vault.totalAssets(), 120 * ONE);
    }

    // ─── Liveness: cap never blocks withdrawals (ADR-007) ─────

    function test_cap_doesNotBlockWithdraw_evenBelowTotalAssets() public {
        // Deposit under a generous cap.
        vm.prank(governance);
        vault.setDepositCap(100 * ONE);
        _deposit(alice, 80 * ONE);

        // Governance tightens the cap BELOW current TVL: new deposits blocked...
        vm.prank(governance);
        vault.setDepositCap(10 * ONE);
        assertEq(vault.maxDeposit(bob), 0);

        // ...but alice can still withdraw her full balance (liveness preserved).
        uint256 maxW = vault.maxWithdraw(alice);
        assertGt(maxW, 0);
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ─── Emergency shutdown still zeroes capacity regardless of cap ───

    function test_emergencyShutdown_overridesCap() public {
        vm.prank(governance);
        vault.setDepositCap(100 * ONE);
        assertEq(vault.maxDeposit(alice), 100 * ONE);

        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }
}
