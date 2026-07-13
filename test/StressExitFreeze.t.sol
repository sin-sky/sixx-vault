// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {FaultyAdapter} from "./mocks/FaultyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StressUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title Stress-exit freeze — Threat Council finding #1 (liveness, HIGH) + ADR-007 #1 fix
/// @notice Threat council (2026-07-11) found that when an adapter's realizable value drops
///         below its reported NAV mark (depeg / slippage beyond the haircut), the
///         `require(received >= mark)` guard (M13-16) froze de-risking. ADR-007 #1 (SHIN
///         approved 2026-07-11) lands the MINIMAL fix — force-detach try/catch on
///         setAdapter(address(0)) + totalAssets fault-tolerance on setAdapter/shutdown
///         (+ an Ethena governance slippage setter, tested separately). These tests now
///         assert the FIXED behaviour:
///           #1 a single user still cannot over-extract past realizable (per-user guard kept);
///           #2 governance CAN force-detach to idle and users then exit pro-rata at honest NAV;
///           #3 emergency shutdown survives a reverting withdraw (unchanged, try/catch);
///           #4 emergency shutdown now survives a reverting totalAssets() (fixed).
/// @dev Mark > realizable is modelled with FaultyAdapter.setDeliverBps(< 10000);
///      a broken oracle with FaultyAdapter.setRevertOnTotalAssets(true).
contract StressExitFreezeTest is Test {
    StressUSDC      usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    FaultyAdapter   faulty;

    address governance   = address(0xBEEF);
    address alice        = address(0xA11CE);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    uint256 constant USDC_6 = 1e6;
    uint256 constant AMOUNT = 10_000 * USDC_6;

    // Mirror of ISIXXVault event for vm.expectEmit.
    event AdapterForceDetached(address indexed adapter, uint256 marked, uint256 received);

    function setUp() public {
        usdc = new StressUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        faulty = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(faulty), "Test", "Faulty");
        vault.setAdapter(address(faulty));
        vm.stopPrank();

        usdc.mint(alice, AMOUNT);
        vm.startPrank(alice);
        usdc.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT, alice);
        vm.stopPrank();
    }

    /// #1 — ADR-007 柱1: under a 1% realizable shortfall a user exit is an honest PARTIAL FILL,
    ///      NOT a brick. The old "VAULT: adapter shortfall" revert is gone — the caller receives
    ///      the realizable ~99% and keeps the unrealized ~1% as residual shares (durable claim).
    function test_stress_userExit_partialFills_whenRealizableBelowMark() public {
        faulty.setDeliverBps(9_900); // realizable = 99% of NAV mark

        uint256 shares = vault.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = vault.redeem(shares, alice, alice); // must NOT revert (no brick)

        assertEq(usdc.balanceOf(alice) - balBefore, payout, "receives the actual cash delivered");
        assertApproxEqRel(payout, (AMOUNT * 9_900) / 10_000, 0.01e18, "~99% realizable delivered");
        assertGt(vault.balanceOf(alice), 0, "residual ~1% retained as a claim, never stuck");
    }

    /// #2 — ADR-007 #1 FIX: governance can force-detach (setAdapter(0)) even under a
    ///      shortfall. It recovers the realizable amount to idle, writes off the (small,
    ///      real) mark>realizable gap, and — crucially — users can then withdraw pro-rata
    ///      from idle at the honest NAV. De-risking is no longer frozen.
    function test_forceDetach_succeeds_underShortfall_thenUsersExitProRata() public {
        faulty.setDeliverBps(9_900); // realizable = 99% of the NAV mark

        // The event must report the true recalled amount (marked=10k, received=9.9k),
        // which pins the `received = balanceAfter - balBefore` measurement.
        vm.expectEmit(true, false, false, true, address(vault));
        emit AdapterForceDetached(address(faulty), AMOUNT, (AMOUNT * 9_900) / 10_000);
        vm.prank(governance);
        vault.setAdapter(address(0)); // force-detach: MUST NOT revert now

        // Detached to idle; realized 99% recovered, the 1% mark gap written off.
        assertEq(vault.activeAdapter(), address(0), "strategy paused to idle");
        assertEq(usdc.balanceOf(address(vault)), (AMOUNT * 9_900) / 10_000, "realized recovered to idle");
        assertApproxEqAbs(vault.totalAssets(), (AMOUNT * 9_900) / 10_000, 1, "NAV = honest realized value");

        // Collective liveness restored: Alice exits from idle at the honest (reduced) NAV.
        uint256 shares = vault.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice); // succeeds from idle — no adapter shortfall guard
        assertApproxEqAbs(usdc.balanceOf(alice) - balBefore, (AMOUNT * 9_900) / 10_000, 2, "Alice exits pro-rata");
    }

    /// #3 — The emergency-shutdown valve IS resilient to a fully-frozen `withdraw` (try/catch):
    ///      the flag still takes effect even though the recall reverts. This is the working path.
    function test_stress_emergencyShutdown_survives_frozenWithdraw() public {
        faulty.setRevertOnWithdraw(true); // adapter fully frozen on withdraw

        vm.prank(governance);
        vault.setEmergencyShutdown(true); // must NOT revert

        // Shutdown took effect (deposits blocked) despite the failed recall.
        assertEq(vault.maxDeposit(address(0)), 0, "shutdown active after frozen withdraw");
    }

    /// #4 — ADR-007 #1 FIX: the emergency valve now takes effect even when the adapter's
    ///      `totalAssets()` reverts (read moved inside try/catch). The flag flips and new
    ///      deposits are blocked; governance can then choose to wait for recovery or
    ///      force-detach. Previously this reverted wholesale (valve bricked).
    function test_emergencyShutdown_survives_whenTotalAssetsReverts() public {
        faulty.setRevertOnTotalAssets(true); // e.g. Pendle TWAP oracle not ready

        vm.prank(governance);
        vault.setEmergencyShutdown(true); // MUST NOT revert now

        assertEq(vault.maxDeposit(address(0)), 0, "shutdown active despite reverting totalAssets");
    }
}
