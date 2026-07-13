// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {FaultInjectingAdapter} from "./mocks/FaultInjectingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract E1USDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title E1 — run/first-come behavior of the IMPLEMENTED ADR-007 exit (柱1/柱3/柱4 regression)
/// @notice Originally the pre-implementation gap probe; now that ADR-007 (design c: pro-rata
///         upper-clamp + honest partial-fill + residual shares, mark-price burn per SHIN
///         2026-07-13) is implemented, these cases regression-lock the achieved behavior:
///         NOBODY is stranded on any adapter failure mode (柱1), honest markdown/force-detach
///         give flat payouts (柱2/柱3), and the residual first-mover skew under an overstated
///         mark is bounded (quantified in test/ExitSkewM1.t.sol → bounded by e).
contract ExitFairnessE1Test is Test {
    E1USDC          usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    FaultInjectingAdapter adapter;

    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    uint256 constant U = 1e6;            // 1 USDC
    uint256 constant D = 10_000 * U;     // each user's deposit
    uint256 constant N = 5;              // number of equal-share users
    address[N] users;

    function setUp() public {
        usdc = new E1USDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new FaultInjectingAdapter(address(usdc), address(vault), governance);
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Fault");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        for (uint256 i = 0; i < N; i++) {
            users[i] = address(uint160(0xE100 + i));
            usdc.mint(users[i], D);
            vm.startPrank(users[i]);
            usdc.approve(address(vault), D);
            vault.deposit(D, users[i]); // all pushed to adapter
            vm.stopPrank();
        }
        // Seed idle = 30% of TVL by pulling it straight out of the adapter into the vault.
        // Faithful: totalAssets() is unchanged (idle + adapter mark == TVL); it just splits the
        // liquidity 30% liquid / 70% deployed, the state the run scenario assumes.
        uint256 tvl = vault.totalAssets();
        vm.prank(address(vault));
        adapter.withdraw((tvl * 30) / 100, address(vault));
    }

    // ── scenario runner: each user redeems ALL shares in order; record cash received ──
    struct Outcome {
        uint256[N] received;   // cash actually taken home, in exit order
        bool[N]    stuck;      // true if redeem reverted (claim remains as shares)
        uint256    cashOut;    // count who took cash
        uint256    stuckCount; // count stranded
    }

    function _run(string memory label) internal returns (Outcome memory o) {
        emit log_string(label);
        for (uint256 i = 0; i < N; i++) {
            uint256 sh = vault.balanceOf(users[i]);
            uint256 before = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            try vault.redeem(sh, users[i], users[i]) {
                o.received[i] = usdc.balanceOf(users[i]) - before;
                o.cashOut++;
            } catch {
                o.received[i] = 0;
                o.stuck[i] = true;
                o.stuckCount++;
            }
            emit log_named_uint(o.stuck[i] ? "  user STUCK (claim only)" : "  user cash", o.received[i]);
        }
        emit log_named_uint("  cashOut count", o.cashOut);
        emit log_named_uint("  stuck count", o.stuckCount);
    }

    // ── Case A: adapter mark OVERSTATES realizable (thin liquidity / stale mark), deliver 50% ──
    function test_E1_A_partialUnderDelivery_markOverstates() public {
        adapter.setDeliverBps(5_000); // realizable = 50% of mark
        Outcome memory o = _run("CASE A: partial under-delivery (deliverBps=50%, mark unchanged)");
        // ADR-007 柱1: honest partial-fill strands NOBODY, even with an overstated mark.
        assertEq(o.stuckCount, 0, "A: no exiter stranded (honest partial-fill)");
        assertEq(o.cashOut, N, "A: every exiter took some cash");
        // 柱3: the residual first-mover skew is bounded (quantified as < e in ExitSkewM1). Here it
        //   must at least stay well under 2x for deliver=50% (measured ~1.10x).
        uint256 skewX1e4 = o.received[N-1] == 0 ? type(uint256).max : (o.received[0] * 1e4) / o.received[N-1];
        emit log_named_uint("  first/last received ratio x1e4", skewX1e4);
        assertLt(skewX1e4, 20_000, "A: bounded skew, not first-come monopoly");
    }

    // ── Case B: adapter fully bricked (withdraw reverts) ──
    function test_E1_B_fullyBricked_withdrawReverts() public {
        adapter.setRevertOnWithdraw(true);
        Outcome memory o = _run("CASE B: fully bricked (withdraw reverts)");
        // 柱1: the adapter withdraw reverts, but the vault catches it (fromAdapter=0) and each
        //   exiter still draws its pro-rata slice of the idle buffer — nobody is stranded, and
        //   the unrealized remainder is retained as residual shares (柱4).
        assertEq(o.stuckCount, 0, "B: bricked adapter strands nobody (idle pro-rata + residual)");
        assertEq(o.cashOut, N, "B: every exiter took some idle-backed cash");
    }

    // ── Case C: HONEST loss — adapter burns 50% of its holdings (mark drops with realizable) ──
    function test_E1_C_honestLoss_markDropsWithRealizable() public {
        uint256 adapterBal = adapter.realBalance();
        adapter.realizeLoss(adapterBal / 2, address(0xDEAD)); // burn half; mark falls too
        Outcome memory o = _run("CASE C: honest markdown (realizeLoss 50% of adapter)");
        // Everyone exits at the SAME (lower) price and takes cash — no first-come monopoly.
        assertEq(o.stuckCount, 0, "C: honest markdown strands nobody");
        for (uint256 i = 1; i < N; i++) {
            assertApproxEqRel(o.received[i], o.received[0], 0.01e18, "C: equal price for all exiters");
        }
    }

    // ── Case D: governance force-detach of a partial adapter, THEN users exit ──
    function test_E1_D_forceDetach_thenExit() public {
        adapter.setDeliverBps(5_000); // will realize a writeoff on force-detach recall
        vm.prank(governance);
        vault.setAdapter(address(0)); // force-detach: recalls what it can, marks the writeoff
        Outcome memory o = _run("CASE D: force-detach (partial), then exit against idle-only NAV");
        emit log_named_uint("  totalAssets after all exits", vault.totalAssets());
        // Force-detach honestly writes the mark down to realizable → fair pro-rata for all.
        assertEq(o.stuckCount, 0, "D: force-detach writedown lets everyone exit");
        for (uint256 i = 1; i < N; i++) {
            assertApproxEqRel(o.received[i], o.received[0], 0.01e18, "D: equal price after writedown");
        }
    }

    // ── Case E: emergency shutdown mass exit with a partial adapter ──
    function test_E1_E_shutdown_massExit_partial() public {
        adapter.setDeliverBps(5_000);
        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true); // recalls what it can (best-effort), waives locks
        Outcome memory o = _run("CASE E: shutdown mass exit (adapter delivers 50%)");
        emit log_named_uint("  totalAssets after exits", vault.totalAssets());
        // ADR-007: shutdown tops up idle with a best-effort recall AND every exit is an honest
        //   partial-fill — so even with a still-overstated mark the tail is NOT stranded; each
        //   exiter takes its pro-rata slice and retains residual shares for the rest (柱1/柱4).
        assertEq(o.stuckCount, 0, "E: shutdown + partial-fill strands nobody");
        assertEq(o.cashOut, N, "E: every exiter took some cash under shutdown");
    }
}
