# ADR-007 pro-rata exit — pre-freeze measurement battery (M-1 … M-5)

> **Status: IN PROGRESS.** SHIN ruled (2026-07-13) burn price stays at **mark** (`convertToShares`);
> realizable-price switch **rejected** (would lock temporary illiquidity as permanent loss, is
> attacker-inducible via a deliberately thin recall = D-4 #3, and breaks 柱4). The residual ~10%
> first-mover skew is NOT a burn-price bug — it is a *stale-overstated-mark* window issue, to be
> defended by fast detection + `force-detach`. This battery quantifies and bounds that residual
> before re-freeze. **No re-freeze / tag / bundle / broadcast until M-1…M-5 are all green.**

Harnesses: `test/ExitSkewM1.t.sol` (M-1), `test/ExitFairnessE1.t.sol` (production-src run probe),
`test/ExitFairnessDesignD2.t.sol` (pre-impl model, retained for provenance).

---

## M-1 — first-mover skew as a function of mark overstate rate → **BOUNDED BY e (~2.718×)**

Measured on the **real** `SIXXVault` ADR-007 exit path (mark-price burn), canonical run:
idle = 30% of TVL, adapter mark = 70%, 5 equal holders each `redeem` all shares in order.
`FaultInjectingAdapter.deliverBps` sets realizable = `deliverBps%` of mark; the **un-delivered
slice stays counted in the mark** (`withdraw` decrements `_balance` by delivered only) = a
*persistent* overstatement, exactly the 柱2-broken window.

### A) skew vs overstate rate (idle = 30%, N = 5)

| deliverBps | overstate = 1/bps | first → last (USDC) | first/last skew |
|---:|---:|---|---:|
| 9000 (90%) | 1.11× | 9300 → 9263 | 1.004× |
| 7000 (70%) | 1.43× | 7900 → 7646 | 1.033× |
| 5000 (50%) | 2.0× | 6500 → 5921 | 1.098× |
| 3000 (30%) | 3.33× | 5100 → 4133 | 1.234× |
| 1000 (10%) | 10× | 3700 → 2304 | 1.606× |
| 100 (1%) | 100× | 3070 → 1470 | 2.088× |
| **0** | **∞ (adapter dead)** | 3000 → 1377 | **2.178× (asymptote)** |

Skew **decelerates** as overstatement grows and converges to a finite asymptote (2.178× here).
It is **NOT linear/unbounded in the overstate rate** — an oracle that lies harder does not widen
the skew without limit.

### B) the bound vs idle fraction (bps = 0, worst overstate, N = 5)

| idle % | first/last skew |
|---:|---:|
| 50% | 1.966× |
| 30% | 2.178× |
| 10% | 2.359× |
| 5% | 2.401× |
| 1% | **2.433×** |

Even as the idle buffer → 0 the skew converges (does not blow up). A larger idle buffer only
*reduces* skew below the cap.

### Closed form + absolute bound

At the worst overstate (bps = 0, so the adapter-delivered term → 0) with idle → 0, each exiter
draws pro-rata of the idle buffer while under-burning at mark price. The recurrence solves to a
first/last skew of

```
skew(N) = (1 − 1/N)^−(N−1)
```

Measured N=5, idle=1% = **2.4333×** vs closed form `(0.8)^−4 = 2.4414×` (matches within the
finite-idle approximation). `skew(N)` is increasing in N with supremum

```
lim_{N→∞} (1 − 1/N)^−(N−1) = e ≈ 2.71828
```

**Conclusion (M-1):** the first-mover advantage from the retained mark-price burn is **provably
bounded by e ≈ 2.72×** (first-of-queue vs last-of-queue) across *all* overstate rates, *all* idle
fractions, and *all* N. The mechanism that causes the skew (mark-price under-burn → residual
shares) is the same one that bounds it: residual shares keep `totalSupply` high, so the pro-rata
denominator never collapses and late exiters always retain a real slice. Regression-locked in
`test/ExitSkewM1.t.sol` (`assertLt(skew, e)` on every sweep point + closed-form anchor test).

> Framing for the residual-risk register (M-3): the skew is a *bounded value-timing* effect, not an
> unbounded drain. It is 1.0× (no skew) whenever the mark is honest (E1 Case C/D: flat payouts),
> and only appears in the stale-overstated-mark window before `force-detach`. Worst case an early
> exiter realizes at most ~e× the cash a last exiter realizes *in that window*; the last exiter is
> not stranded (柱1) and retains residual shares that recover value once the mark is corrected (柱4).

---

## M-2 — do the REAL SIXX marks persistently overstate realizable? → two classes

Every adapter's `totalAssets()` (the vault's mark) was read against how its `withdraw` actually
realizes cash. Result: the four adapters fall into two structural classes.

### Class L — liquidity-only overstatement, self-correcting (Aave, Venus)

| Adapter | Mark (`totalAssets`) | Overstates realizable only when | Direction of staleness |
|---|---|---|---|
| `AaveV3USDCAdapter` | `aToken.balanceOf` (aUSDC ≈ 1:1 USDC) | Aave USDC market utilization → 100% (no cash to redeem) | balanceOf exact; illiquidity is external |
| `VenusUSDTAdapter` | `vToken.balanceOf × exchangeRateStored` | Venus USDT market illiquid (high utilization) | `exchangeRateStored` lags **UNDER** (safe) between interactions |

- The mark can only exceed realizable when the money market **temporarily has no cash** to honor a
  redemption (utilization spike). Aave/Venus interest-rate curves spike borrow APR at high
  utilization → borrowers repay / suppliers arrive → cash returns. Historically minutes–hours.
- This is the **frozen→thaw** case (E1 pillar-4 / design D-3): residual shares recover **full** value
  on thaw. 柱4 is exactly right here; there is no *persistent* overstatement in normal operation.
- A permanent loss (protocol bad debt) is a **different** case — it is honestly written down (the
  money market socializes it, or governance `force-detach`), giving **flat** payouts (E1 Case C). It
  is not a stale-overstated mark.
- **Persistent-overstatement window ≈ 0** in normal operation; otherwise bounded by the money
  market's utilization-normalization time (self-correcting) or by `force-detach` for a frozen /
  bad-debt market.

### Class P — peg-blind valuation, CAN persist (Ethena, Pendle)

| Adapter | Mark | Peg-blind because | Built-in buffer |
|---|---|---|---|
| `EthenaSUSDeAdapter` | `convertToAssets(sUSDe) × (1 − slippageBps)` | `convertToAssets` is Ethena's **internal** USDe rate — blind to a USDe market depeg | `slippageBps` haircut, **≤ `MAX_SLIPPAGE_BPS = 300` (3%)** |
| `PendlePTAdapter` | `min(TWAP PtToAssetRate, 1e18) × ptBal`; post-maturity = par | par-cap assumes USDe≈USDC 1:1; a USDe depeg is "a disclosed risk, not priced by a spot" (src comment) | TWAP window ≥ 15 min (smoothing) + par-cap (never over-marks *above* par) |

- The real persistent-overstatement scenario is a **USDe / sUSDe depeg**: `convertToAssets` (Ethena)
  and post-maturity par redemption (Pendle) keep returning ~par while the DEX-realizable value has
  dropped. The mark overstates realizable by `(depeg discount − buffer)`.
- Buffers absorb **small** deviations only: Ethena ≤ 3%; Pendle's TWAP smooths a sudden drop over
  ≥ 15 min and the par-cap blocks over-marking above par (but not a depeg *below* par).
- On a depeg **deeper than the buffer**, each adapter's own `withdraw` `min_dy` **reverts**; the
  vault wraps that recall in try/catch (`_exitRealize`), so `fromAdapter = 0` and the exit degrades
  to the caller's **idle pro-rata** — precisely the M-1 `deliverBps → 0` point ⇒ skew bounded by e.
- Correction levers, by latency:
  1. Ethena `setSlippageBps` → writes NAV down by **at most 3%**. Sufficient for a shallow wobble,
     **insufficient** for a deep depeg (> 3%).
  2. **`force-detach` (`vault.setAdapter(address(0))`)** → recalls best-effort and writes the mark
     down to realizable ⇒ **flat** payouts thereafter (E1 Case D, asserted). This is the real
     correction for a deep depeg and is always available (bypasses the registry, H-1).
- **Persistent-overstatement window = (depeg depth beyond buffer) × (detection → `force-detach`
  latency).** Magnitude of the resulting skew is bounded by e (M-1); duration is bounded by the
  monitoring/response latency — whose existence is the subject of **M-3**.

### M-2 conclusion

No SIXX mark overstates realizable *without bound or indefinitely on its own*. Class L overstatements
are transient liquidity events that the residual-share design already handles fairly (value recovers
on thaw). Class P (Ethena/Pendle depeg) is the only mark that can *persist*, and only for the window
between depeg onset and `force-detach`; within that window the first-mover skew is bounded by e (M-1),
nobody is stranded (柱1), and residual shares recover value once the mark is corrected (柱4). The
residual therefore reduces to **"detect a deep Class-P depeg and force-detach quickly"** → M-3.

---

## M-3 — residual canonized + detection/ops guarantee

Done. The residual is written into `docs/architecture/decisions/007-exit-is-never-blocked.md`
(Consequences: bounded-by-e, honest-mark ⇒ flat, defended operationally not at the burn-price layer).
The detection + force-detach procedure now exists as
`docs/operations/depeg-mark-staleness-runbook.md` (signals A/B/C, WARN/ACT thresholds, force-detach
steps, 30-min latency budget). Live-monitor wiring + governance expedited-detach path are filed as an
ops-infra task (runbook §5) and referenced from mainnet-gate G3.

---

## M-4 — adversarial code check of the exit path (`test/ExitAdversarialM4.t.sol`)

Verified on the real `SIXXVault`:

- **Happy path is NOT degraded (exact to the wei).** In normal operation (`idle == 0`,
  `lockedProfit == 0`, healthy adapter), `withdraw(assets)` delivers exactly `assets` and burns
  exactly `previewWithdraw(assets)` shares; `redeem(shares)` delivers exactly `previewRedeem(shares)`
  and burns **all** shares (no dust residual). Analytically this holds because with `idle0 == 0` the
  single `mulDiv(mark, shares, supply)` recall equals `convertToAssets(shares)`, so `payout ==
  requested` ⇒ the full-fill branch (`sBurn = shares`). (When `idle0 > 0` **and** an adapter is
  attached, the two separate `mulDiv` floors can lose ≤ 1 wei ⇒ a partial-fill classification that
  under-pays by ≤ 1 wei and leaves ≤ 1-wei-worth residual share — always **protocol-favorable**
  (`payout ≤ requested`, never over-pays) and confined to non-normal states (post-shutdown /
  leftover-idle). Documented as benign.)
- **No theft via split exits.** Under a rate-limiting adapter (delivers 50%/call, destroys no value),
  an attacker splitting into 100 tiny redeems realizes at most **their own deposit** (measured 750 of
  1000, never > 1000) and the co-holder's shares stay intact. `sBurn = convertToShares(payout, Ceil)`
  (round **up**) makes every partial burn ≥ the exact share-cost of the cash, so repeated partials
  can never compound rounding into extraction of another holder's principal.
- **柱1 never-revert holds across every adapter failure mode.** `redeem` and `withdraw` both complete
  (no revert, never take cash away) under: `deliverBps = 0` (delivers nothing), `deliverBps = 1`,
  `revertOnWithdraw`, `revertOnTotalAssets` (valuation reverts → `totalAssets` degrades to
  `_totalDebt`), and both reverts together. Confirmed for all 5 modes × {redeem, withdraw}.
- **Diff-line mutation (`scripts/mutation-diffscope.sh`, tip `9c7c9e7`):** 198 mutants land on the
  changed exit-path lines (withdraw/redeem bodies + `_exitRealize` + `_completeExit`, incl. the
  F-2/F-3 lines) run against the full non-fork suite. Baseline run: **killed 183 / survived 15 →
  92.4%** (`reports/mutation/diffscope-report.md`). Every survivor triaged (`audit/MUTATION_TRIAGE.md`
  Round-8 addendum): **10 = reachable test gaps → killed by 10 added exit-path regressions** (each
  proven by applying the mutant individually: PASS on clean, FAIL under mutant), **5 = proven
  equivalent** (unreachable defense-in-depth: #475 gas guard, #556/#564/#565/#567 the 柱4 `sBurn`
  cap which `convertToShares` monotonicity makes unreachable). Post-fix non-fork suite = **318
  tests / 0 fail**, reproduced on the frozen `audit/round8-hardening` tree under a pre/post
  clean-tree guard. Effective (non-equivalent) mutation score = **193/193 = 100%**. The F-2 (#438)
  and F-3 (#456) fixes are **pinned by direct unit tests** (`test_exitRealize_markFallback_*`,
  `test_exitRealize_noOverRecall_whenIdlePresent`), not by reduced-fuzz invariant/Echidna coverage —
  both survived the reduced-run suite, so they regress-fail the instant the fix breaks.

### F-2 / F-3 / F-4 remediation (SHIN 2026-07-13, independent of F-1)

Three defects in the first-cut ADR-007 exit were found and fixed as small diffs; each was
re-hammered (D-4 attack surface, happy-path non-degradation, diff-mutation):

- **F-2 (High — H-02 / 柱1 regression).** `_exitRealize` set `mark = 0` in the `catch` when
  `adapter.totalAssets()` reverted ⇒ `wantAdapter = 0` ⇒ **no recall** ⇒ funds stranded behind a
  still-functional `withdraw` — reviving the exact exit-brick H-02 fixed elsewhere. Fixed to degrade
  to `mark = _totalDebt` (the same fallback `totalAssets()` uses), so a broken oracle never zeroes
  the recall. Regression: `test_H02_recall_fallsBack_whenTotalAssetsReverts_noShutdown`.
- **F-3 (Medium — INV-3).** The recall pulled the **raw-mark** pro-rata (`mulDiv(mark, shares,
  supply)`) but paid the `lockedProfit`-adjusted claim; the excess (the still-locked profit slice)
  was recalled into idle and **stranded**, tripping the non-custody-no-idle invariant
  (`INV-3: unexpected idle balance`). Fixed by capping `wantAdapter = min(proRataMark,
  requestedAssets − idleShare)` so only what is needed to pay the request is recalled. Regression:
  the invariant suite (`INV-3`) now passes.
- **F-4 (Low).** `withdraw`/`redeem` reverted a bare string on the max-cap breach; restored to the
  OZ `ERC4626ExceededMaxWithdraw` / `ERC4626ExceededMaxRedeem` custom errors that `super` would
  raise (ERC-4626 compliance; lock surfaces here because `maxWithdraw`/`maxRedeem` return 0 while
  locked, H-4).

Full non-fork suite after remediation: **305 tests, 0 failures** (all 8 tests that encoded the old
revert-on-shortfall behavior reconciled to the ADR-007 partial-fill semantics).
- **Test reconciliation:** the 2 unit tests broken by the redesign were reconciled — the lock test
  now asserts the ERC-4626 `ERC4626ExceededMaxRedeem` custom error (restored: `withdraw`/`redeem`
  now revert the same OZ custom errors `super` would, not a bare string), and the old
  "recall reverts on adapter shortfall" test was rewritten to assert the new partial-fill semantics
  (`test_exit_partialFills_onAdapterShortfall_noRevert`). The `ExitFairnessE1` suite was converted
  from a pre-implementation probe into a regression suite (all 5 cases: `stuck == 0`).
