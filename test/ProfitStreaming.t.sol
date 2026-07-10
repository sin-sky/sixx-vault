// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {HarvestAdapter} from "./mocks/HarvestAdapter.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PsUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title Profit streaming — ADR-007 #2 structural JIT defense
/// @notice A discrete-harvest adapter (HarvestAdapter) recognizes yield in a lump at harvest().
///         Without streaming this is JIT-skimmable: deposit right before harvest, exit right
///         after, capture yield you didn't earn. With locked-profit degradation the harvested
///         gain unlocks linearly over PROFIT_UNLOCK_PERIOD (8h), so a same-instant depositor
///         gets ~nothing and long-term holders receive it.
contract ProfitStreamingTest is Test {
    PsUSDC          usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    HarvestAdapter  adapter;

    address governance   = address(0xBEEF);
    address alice        = address(0xA11CE);
    address bob          = address(0xB0B); // the JIT attacker
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    uint256 constant USDC_6 = 1e6;
    uint256 constant PERIOD = 8 hours;

    function setUp() public {
        usdc = new PsUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new HarvestAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Harvest");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        usdc.mint(alice, 100_000 * USDC_6);
        usdc.mint(bob,   100_000 * USDC_6);
        usdc.mint(address(this), 100_000 * USDC_6); // for funding rewards
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _fundReward(uint256 amt) internal {
        usdc.approve(address(adapter), amt);
        adapter.addReward(amt); // pending; excluded from totalAssets until harvest
    }

    /// @notice The JIT depositor cannot skim harvested profit: enters right before harvest,
    ///         exits right after, and recovers ~only their principal.
    function test_jit_cannotSkimHarvestProfit() public {
        _deposit(alice, 10_000 * USDC_6); // long-term holder
        _fundReward(1_000 * USDC_6);       // a year's reward, pending realization

        uint256 bobShares = _deposit(bob, 10_000 * USDC_6); // JIT enters just before harvest

        vault.harvest(); // realizes +1_000 into the adapter, but LOCKS it
        assertApproxEqAbs(vault.lockedProfit(), 1_000 * USDC_6, 2, "profit locked at harvest");

        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob); // JIT exits immediately
        uint256 got = usdc.balanceOf(bob) - balBefore;

        // Bob recovers ~his 10k principal, NOT ~10.5k — he skimmed essentially none of the 1k.
        assertApproxEqRel(got, 10_000 * USDC_6, 0.005e18, "JIT exit ~= principal, no skim");
        assertLt(got, 10_050 * USDC_6, "JIT captured < 0.5% of the reward");
    }

    /// @notice Locked profit degrades linearly to 0 over the unlock window.
    function test_lockedProfit_degradesLinearly() public {
        _deposit(alice, 10_000 * USDC_6);
        _fundReward(1_000 * USDC_6);
        vault.harvest();

        uint256 navAtHarvest = vault.totalAssets();
        assertApproxEqAbs(vault.lockedProfit(), 1_000 * USDC_6, 2, "fully locked at t0");

        vm.warp(block.timestamp + PERIOD / 2);
        assertApproxEqAbs(vault.lockedProfit(), 500 * USDC_6, 1e4, "half unlocked at t/2");
        assertGt(vault.totalAssets(), navAtHarvest, "NAV rises as profit unlocks");

        vm.warp(block.timestamp + PERIOD); // past full window
        assertEq(vault.lockedProfit(), 0, "fully unlocked");
        assertApproxEqAbs(vault.totalAssets(), 11_000 * USDC_6, 2, "NAV = principal + full reward");
    }

    /// @notice The long-term holder receives the streamed profit once it fully unlocks.
    function test_longTermHolder_receivesUnlockedProfit() public {
        uint256 aliceShares = _deposit(alice, 10_000 * USDC_6);
        _fundReward(1_000 * USDC_6);
        vault.harvest();

        vm.warp(block.timestamp + PERIOD + 1);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        uint256 got = usdc.balanceOf(alice) - balBefore;
        assertApproxEqRel(got, 11_000 * USDC_6, 0.005e18, "holder gets principal + reward");
    }

    /// @notice Backward-compat: a continuous-accrual adapter (harvest no-op) locks nothing;
    ///         totalAssets is unchanged by harvest().
    function test_harvest_noop_onContinuousAdapter_locksNothing() public {
        // Swap to a plain MockAdapter (harvest returns 0, totalAssets does not jump).
        MockAdapter mock = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(mock), "DeFi", "Mock");
        vault.setAdapter(address(mock));
        vm.stopPrank();

        _deposit(alice, 10_000 * USDC_6);
        uint256 navBefore = vault.totalAssets();
        uint256 profit = vault.harvest();
        assertEq(profit, 0, "no discrete profit on continuous adapter");
        assertEq(vault.lockedProfit(), 0, "nothing locked");
        assertEq(vault.totalAssets(), navBefore, "totalAssets unchanged by harvest");
    }

    /// @notice harvest() while the strategy is paused (activeAdapter == 0) is a safe no-op
    ///         (does not call the zero adapter). Kills the `adapter_ != address(0)` mutation.
    function test_harvest_whilePaused_noopNoRevert() public {
        _deposit(alice, 10_000 * USDC_6);
        vm.prank(governance);
        vault.setAdapter(address(0)); // pause to idle

        uint256 profit = vault.harvest(); // must not revert / must not touch address(0)
        assertEq(profit, 0, "no profit while paused");
        assertEq(vault.lockedProfit(), 0, "nothing locked while paused");
    }
}
