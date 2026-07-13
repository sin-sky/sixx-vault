// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title D-2 — pre-implementation numeric comparison of three exit designs
/// @notice PURE MODEL. No production src, no vault. Simulates the run scenario
///         (idle 30% / adapter 70%, N equal-share users exiting in order) under a fixed
///         realizable pool (adapter can deliver only 50% of its MARK — thin liquidity / stale
///         mark) for three payout rules, and prints per-user cash, stuck count, and final-price
///         equality. R8-1 lesson: measure the new design's run BEFORE writing any src.
///
///         Impairment model: adapter MARK = 35_000 but only realizable pool R = 17_500 is
///         deliverable; idle = 15_000. Face NAV = 50_000; realizable NAV = 32_500. 5 equal users.
contract ExitFairnessDesignD2Test is Test {
    using Math for uint256;

    uint256 constant U = 1e6;
    uint256 constant N = 5;
    uint256 constant SHARE = 1e18;          // each user's share units
    uint256 constant IDLE0 = 15_000 * 1e6;  // 30%
    uint256 constant POOL0 = 17_500 * 1e6;  // realizable in adapter (50% of mark)
    uint256 constant MARK0 = 35_000 * 1e6;  // adapter MARK (overstates realizable)

    struct Result {
        uint256[N] received;
        bool[N]    stuck;      // true = redeem reverted, claim (shares) retained
        uint256[N] residual;   // share units kept as a claim (柱4)
        uint256    cashCount;  // users who took >0 cash
        uint256    stuckCount; // users who reverted (0 cash, no partial)
    }

    function _init() internal pure returns (uint256[N] memory sh) {
        for (uint256 i = 0; i < N; i++) sh[i] = SHARE;
    }

    // ── (a) CURRENT: idle-first, just-enough recall, all-or-revert (no governance) ──
    function _designA() internal pure returns (Result memory r) {
        uint256 idle = IDLE0; uint256 pool = POOL0; uint256 mark = MARK0; uint256 supply = N * SHARE;
        uint256[N] memory sh = _init();
        for (uint256 i = 0; i < N; i++) {
            uint256 faceTVL = idle + mark;
            uint256 claim = sh[i].mulDiv(faceTVL, supply);
            if (idle >= claim) {
                idle -= claim; r.received[i] = claim; r.cashCount++;
            } else {
                uint256 needed = claim - idle;
                uint256 deliver = needed <= pool ? needed : pool;
                if (deliver < needed) { r.stuck[i] = true; r.residual[i] = sh[i]; r.stuckCount++; continue; }
                pool -= deliver; mark -= deliver; idle = idle + deliver - claim;
                r.received[i] = claim; r.cashCount++;
            }
            supply -= sh[i]; sh[i] = 0;
        }
    }

    // ── (b) PILLAR-1 ONLY: idle-first-full, honest partial-fill, NO clamp (revert removed) ──
    function _designB() internal pure returns (Result memory r) {
        uint256 idle = IDLE0; uint256 pool = POOL0; uint256 mark = MARK0; uint256 supply = N * SHARE;
        uint256[N] memory sh = _init();
        for (uint256 i = 0; i < N; i++) {
            uint256 faceTVL = idle + mark;
            uint256 claim = sh[i].mulDiv(faceTVL, supply);
            uint256 avail = idle + pool;
            uint256 pay = claim <= avail ? claim : avail;
            uint256 fromIdle = pay <= idle ? pay : idle;
            uint256 fromPool = pay - fromIdle;
            idle -= fromIdle; pool -= fromPool; mark -= fromPool;
            uint256 burn = claim == 0 ? sh[i] : sh[i].mulDiv(pay, claim);
            sh[i] -= burn; supply -= burn;
            r.received[i] = pay;
            r.residual[i] = sh[i];
            if (pay > 0) r.cashCount++; else r.stuckCount++;
        }
    }

    // ── (c) PILLAR-1 + PILLAR-3 FUSED: pro-rata upper-clamp against realizable NAV ──
    function _designC() internal pure returns (Result memory r) {
        uint256 idle = IDLE0; uint256 pool = POOL0; uint256 supply = N * SHARE;
        uint256[N] memory sh = _init();
        for (uint256 i = 0; i < N; i++) {
            uint256 realTVL = idle + pool;                       // honest realizable NAV
            uint256 entitled = sh[i].mulDiv(realTVL, supply);    // pro-rata slice of realizable
            uint256 avail = idle + pool;
            uint256 pay = entitled <= avail ? entitled : avail;  // == entitled here
            uint256 fromIdle = pay <= idle ? pay : idle;
            uint256 fromPool = pay - fromIdle;
            idle -= fromIdle; pool -= fromPool;
            uint256 burn = entitled == 0 ? sh[i] : sh[i].mulDiv(pay, entitled); // full when pay==entitled
            sh[i] -= burn; supply -= burn;
            r.received[i] = pay;
            r.residual[i] = sh[i];                                // 柱4: unpaid remainder stays as shares
            if (pay > 0) r.cashCount++; else r.stuckCount++;
        }
    }

    function _report(string memory label, Result memory r) internal {
        emit log_string(label);
        for (uint256 i = 0; i < N; i++) {
            emit log_named_uint(r.stuck[i] ? "  received (STUCK/revert)" : "  received", r.received[i]);
        }
        emit log_named_uint("  cash count", r.cashCount);
        emit log_named_uint("  stuck count", r.stuckCount);
        emit log_named_uint("  first/last ratio x1e4",
            r.received[N-1] == 0 ? type(uint256).max : r.received[0].mulDiv(1e4, r.received[N-1]));
    }

    function _allEqual(Result memory r) internal pure returns (bool) {
        for (uint256 i = 1; i < N; i++) {
            if (r.received[i] > r.received[0] + 2 || r.received[0] > r.received[i] + 2) return false;
        }
        return true;
    }

    function test_D2_compareThreeDesigns() public {
        Result memory a = _designA();
        Result memory b = _designB();
        Result memory c = _designC();

        _report("=== (a) CURRENT: idle-first, all-or-revert (no governance) ===", a);
        _report("=== (b) PILLAR-1 ONLY: idle-first-full, honest partial ===", b);
        _report("=== (c) PILLAR-1+3 FUSED: pro-rata upper-clamp ===", c);

        // (a) strands the tail behind a revert; payouts are unequal (first-come full, tail zero).
        assertGt(a.stuckCount, 0, "a: expected reverted/stuck users");
        assertEq(a.received[N-1], 0, "a: last user stranded (revert)");
        assertFalse(_allEqual(a), "a: unequal payouts");
        // (b) removes the revert (no all-or-revert) but PRESERVES first-come: head full, tail zero.
        assertEq(b.received[0], 10_000 * U, "b: first-come takes full face");
        assertEq(b.received[N-1], 0, "b: tail gets no cash despite no revert");
        assertFalse(_allEqual(b), "b: still first-come unequal");
        // (c) equal value for everyone, all cash, nobody stuck — best on 柱1/2/3 simultaneously.
        assertEq(c.stuckCount, 0, "c: nobody gets zero");
        assertTrue(_allEqual(c), "c: equal payout for all exiters");
        for (uint256 i = 0; i < N; i++) {
            assertApproxEqAbs(c.received[i], 6_500 * U, 2, "c: each gets pro-rata of realizable");
        }
    }

    // ── 柱4 without a new subsystem: when LIQUID-now < aggregate entitlement, design (c) pays
    //    the pro-rata of what's liquid and RETAINS the unpaid remainder as ordinary ERC-20 shares.
    //    Those residual shares redeem at the SAME per-share value once liquidity returns — so the
    //    VALUE is fair (everyone ends equal); only the TIMING of cash is first-come. No queue.
    //    Model: adapter portion is FROZEN in pass 1 (only idle is liquid), then THAWS for pass 2.
    function test_D2_pillar4_residualSharesCarryValue_noQueue() public {
        uint256 idle = 5_000 * U;          // liquid now
        uint256 frozen = 5_000 * U;        // real value, NOT deliverable in pass 1
        uint256 supply = N * SHARE;
        uint256[N] memory sh = _init();
        uint256[N] memory cashPass1;

        // realizable NAV (for price/entitlement) counts the frozen value; liquidity does not.
        // PASS 1 — pool frozen: pay = min(pro-rata of realizable NAV, remaining liquid idle).
        for (uint256 i = 0; i < N; i++) {
            uint256 realNAV = idle + frozen;                    // 10_000
            uint256 entitled = sh[i].mulDiv(realNAV, supply);   // 2_000 per full unit
            uint256 pay = entitled <= idle ? entitled : idle;   // capped by LIQUID only
            idle -= pay;
            uint256 burn = entitled == 0 ? 0 : sh[i].mulDiv(pay, entitled);
            sh[i] -= burn; supply -= burn;
            cashPass1[i] = pay;
            emit log_named_uint("  pass1 cash", pay);
            emit log_named_uint("  pass1 residual shares", sh[i]);
        }
        // Pass 1 is first-come on CASH: early users got 2_000, the tail got 0 — but nobody reverted.
        assertEq(cashPass1[0], 2_000 * U, "p1: head got full pro-rata cash");
        assertEq(cashPass1[N-1], 0, "p1: tail got no cash in pass 1");

        // PASS 2 — pool thaws; residual holders redeem at the same per-share value.
        uint256 liquid2 = frozen; // 5_000 now deliverable
        for (uint256 i = 0; i < N; i++) {
            if (sh[i] == 0) continue;
            uint256 realNAV = liquid2;                          // remaining realizable
            uint256 entitled = sh[i].mulDiv(realNAV, supply);
            uint256 pay = entitled <= liquid2 ? entitled : liquid2;
            liquid2 -= pay;
            supply -= sh[i]; sh[i] = 0;
            uint256 total = cashPass1[i] + pay;
            emit log_named_uint("  TOTAL value (pass1+pass2)", total);
            // Every user ends with the SAME fair value (2_000), regardless of exit order.
            assertApproxEqAbs(total, 2_000 * U, 3, "residual shares carried full pro-rata value");
        }
    }
}
