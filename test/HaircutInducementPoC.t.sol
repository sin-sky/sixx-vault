// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title F-1 pre-implementation attack PoC — is a detection-based auto mark-haircut inducible?
/// @notice PURE MODEL (no production src). SHIN gate: before implementing F-1 (auto-haircut that
///         writes the mark down to realizable on observed under-delivery, to flatten the exit
///         skew), prove or refute that the haircut itself is an attack surface. Three probes:
///           A) induced writedown + JIT deposit arbitrage extracts value from stayers when the
///              illiquidity is TEMPORARY and the haircut later reverses;
///           B) a STICKY (non-reversing) haircut instead realizes a PERMANENT phantom loss on a
///              purely temporary illiquidity — early exiters eat a loss that never existed;
///           C) the haircut cannot stop the trigger window — idle-served exits escape at the
///              overstated NAV before any under-delivery is observed (residual first-mover).
///         If A (or B) holds, a naive single-observation auto-haircut is R8-1-class: a new hole.
contract HaircutInducementPoCTest is Test {
    using Math for uint256;

    uint256 constant U = 1e6; // USDC scale

    // ─────────────────────────────────────────────────────────────────────────
    // A) INDUCED WRITEDOWN + JIT DEPOSIT ARBITRAGE (temporary illiquidity, reversing haircut)
    //    The naive rule: on an exit whose recall delivers d<1 of its request, the vault "learns"
    //    realizable and writes effectiveMark := realizable globally. When the (temporary) crunch
    //    resolves, the haircut lifts and NAV recovers. An attacker who INDUCES the haircut, then
    //    deposits cheap during it, harvests the recovery from the stayers.
    // ─────────────────────────────────────────────────────────────────────────
    function test_A_inducedHaircut_JITarbitrage_extractsFromStayers() public {
        // Honest state: 1,000 shares, mark = 1,000 USDC, NAV = 1.0. No real loss.
        uint256 stayerShares = 1_000 * U;
        uint256 realMark      = 1_000 * U; // the TRUE (recoverable) value; illiquidity is temporary
        uint256 supply        = stayerShares;

        // Step 1 — attacker induces a thin recall (realizable observed = 50% of mark) with a dust
        //          exit. Naive auto-haircut writes effectiveMark down to the observed realizable.
        uint256 observedRealizable = realMark / 2;          // 500 — TEMPORARY thinness, not a loss
        uint256 effectiveMark = observedRealizable;          // haircut applied globally
        uint256 navNumX = effectiveMark;                     // NAV = effectiveMark / supply
        emit log_named_uint("A: NAV after induced haircut (x1e6/share)", navNumX.mulDiv(U, supply));

        // Step 2 — attacker deposits 500 USDC at the depressed NAV (0.5) → mints 1,000 new shares.
        uint256 deposit = 500 * U;
        uint256 mintedShares = deposit.mulDiv(supply, effectiveMark); // shares = assets * supply/NAVnum
        supply       += mintedShares;
        effectiveMark += deposit; // real cash added
        emit log_named_uint("A: attacker minted shares", mintedShares);

        // Step 3 — the TEMPORARY crunch resolves; the haircut lifts. effectiveMark returns to the
        //          true recoverable value (realMark) plus the attacker's real deposit.
        effectiveMark = realMark + deposit; // 1,000 + 500 = 1,500 over 2,000 shares → NAV 0.75
        emit log_named_uint("A: NAV after recovery (x1e6/share)", effectiveMark.mulDiv(U, supply));

        // Step 4 — attacker redeems its 1,000 shares at the recovered NAV.
        uint256 attackerOut = mintedShares.mulDiv(effectiveMark, supply);
        supply       -= mintedShares;
        effectiveMark -= attackerOut;
        int256 attackerPnl = int256(attackerOut) - int256(deposit);

        // Stayers: their 1,000 shares are now worth the residual effectiveMark.
        uint256 stayerValueAfter = stayerShares.mulDiv(effectiveMark, supply);
        int256 stayerPnl = int256(stayerValueAfter) - int256(1_000 * U);

        emit log_named_int("A: attacker PnL (USDC-ish)", attackerPnl);
        emit log_named_int("A: stayer PnL (USDC-ish)", stayerPnl);

        // The attack transfers value: attacker profits, stayers lose, roughly conserving.
        assertGt(attackerPnl, 0, "A: inducing a haircut then depositing cheap must NOT be profitable");
        assertLt(stayerPnl, 0, "A: stayers must NOT be robbed by an induced haircut");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // B) STICKY HAIRCUT → PERMANENT PHANTOM LOSS on temporary illiquidity.
    //    To deny attack A's reversal arbitrage one might make the haircut permanent. Then a purely
    //    TEMPORARY crunch is realized as a permanent loss for anyone who exits during it.
    // ─────────────────────────────────────────────────────────────────────────
    function test_B_stickyHaircut_permanentPhantomLoss_onTemporaryIlliquidity() public {
        uint256 supply   = 1_000 * U;
        uint256 realMark = 1_000 * U; // truly recoverable; the crunch is temporary
        uint256 haircutMark = realMark / 2; // sticky haircut to 500 after an observed thin recall

        // A holder who must exit DURING the (temporary) crunch redeems at the haircut NAV.
        uint256 exitShares = 400 * U;
        uint256 exitGot = exitShares.mulDiv(haircutMark, supply); // at NAV 0.5 → 200
        // Their honest, recoverable value was 400 (illiquidity was temporary, not a loss).
        uint256 honestValue = exitShares.mulDiv(realMark, supply);
        emit log_named_uint("B: exiter got (haircut NAV)", exitGot);
        emit log_named_uint("B: exiter's honest value", honestValue);

        assertLt(exitGot, honestValue, "B: sticky haircut realizes a phantom loss on temporary illiquidity");
        // Quantify: half the exiter's principal is destroyed by a crunch that was never a real loss.
        assertApproxEqRel(exitGot, honestValue / 2, 0.01e18, "B: ~50% phantom loss booked");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C) THE HAIRCUT CANNOT STOP THE TRIGGER WINDOW.
    //    The haircut only fires AFTER an under-delivery is observed. Exiters served entirely from
    //    the idle buffer (no adapter recall) never trigger it and escape at the OVERSTATED NAV.
    //    So the residual first-mover advantage the haircut was meant to remove survives for
    //    everyone who fits in idle before the first adapter-touching exit.
    // ─────────────────────────────────────────────────────────────────────────
    function test_C_haircutCannotStopTriggerWindow_residual() public {
        // NAV overstated: mark = 1,000 but realizable = 600. idle buffer = 200.
        uint256 supply = 1_000 * U;
        uint256 markNAV = 1_000 * U;        // overstated
        uint256 idle    = 200 * U;          // liquid, served without touching the adapter

        // Early exiters drawing within idle exit at the OVERSTATED mark NAV (1.0/share) — the
        // haircut never fires because no adapter recall (hence no under-delivery) occurs.
        uint256 earlyShares = 200 * U;      // exactly drains idle at NAV 1.0
        uint256 earlyGot = earlyShares.mulDiv(markNAV, supply); // 200 at the overstated price
        assertLe(earlyGot, idle, "C: idle-served exit");
        // Honest (haircut) value of those shares would have been 0.6/share = 120.
        uint256 honestNAV = 600 * U;
        uint256 earlyHonest = earlyShares.mulDiv(honestNAV, supply);
        emit log_named_uint("C: idle-served early exiter got (overstated)", earlyGot);
        emit log_named_uint("C: their honest (post-haircut) value", earlyHonest);

        // The residual: the trigger window lets ~ idle/NAV of the supply escape overpaid, BEFORE
        // any haircut can engage. The haircut does not close this window.
        assertGt(earlyGot, earlyHonest, "C: idle-served exits overpaid despite the auto-haircut");
        uint256 overpay = earlyGot - earlyHonest;
        emit log_named_uint("C: overpay leaked before haircut triggers", overpay);
        assertGt(overpay, 0, "C: residual first-mover survives the haircut");
    }
}
