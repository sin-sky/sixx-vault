# Round-8 v2 独立監査(6エージェント @ b835c09)— 全裁定台帳(外部監査人向け)

> 監査ラン `wf_b0fe33c6-58f`(workflowName `round8-exit-audit`、5 blind finder A–E + arbiter F)。
> src+test のみ・過去論拠非開示で走行。**raw findings = 7 件**、arbiter 裁定 = `4_NEW_HIGH_MED_TO_FIX`。
> 本台帳は ephemeral なラン出力から全 7 件＋裁定を**コミット物に恒久収載**したもの(SHIN 要請②)。

## 一覧

| # | Lens | 申告 severity | arbiter 裁定 | fix |
|---|---|---|---|---|
| 1 | A | Medium | **NEW_MEDIUM** | YES |
| 2 | B | High | **KNOWN_MITIGATED** | — |
| 3 | B | Medium | **NEW_MEDIUM** | YES |
| 4 | C | High | **NEW_MEDIUM** | YES |
| 5 | D | High | **NEW_MEDIUM** | YES |
| 6 | E | High | **KNOWN_MITIGATED** | — |
| 7 | E | Medium | **KNOWN_MITIGATED** | — |

**収束**: #1(A)/#3(B)/#4(C)/#5(D) は **1 root cause(idle-only burn-price skim)に 4 finder 収束** → NEW_MEDIUM・修正済(F guard `06e13c9`)。
#2(B)/#6(E)/#7(E) は **KNOWN_MITIGATED**(readable/silent overstated-mark residual、既受容・force-detach gated)。

---

## RAW #1 — Lens A — 申告 [Medium] → 裁定 **NEW_MEDIUM** (fix-needed)

**title**: C-1 idle-only exit burns too few shares (sBurn priced against loss-blind overstated NAV) → first-mover extracts value from remaining holders whenever idle>0

**location**: `src/core/SIXXVault.sol:339-396 (_exitRealize, esp. L393 sBurn = _convertToShares(payout, Ceil)) interacting with totalAssets() L186-204 and the C-1 branch L379-381`

**exploit / PoC(finder 申告)**:

> Setup: alice and bob each deposit 10,000 USDC (20,000 total, all deployed, _totalDebt=20,000). Adapter suffers a genuine 50% realized loss (real backing 10,000) and its totalAssets() oracle then reverts. Per H-02, vault.totalAssets() degrades to the loss-blind _totalDebt fallback and OVER-reports NAV (reports 22,000 when there is 2,000 idle + 10,000 real adapter = 12,000 true). Some idle exists (realistic: a prior failed adapter push left funds idle via AdapterDepositFailed / a prior force-detach or shutdown recall / dust from a partial recall — here 2,000). Because valuation is unreadable, _exitRealize takes the C-1 catch: fromAdapter=0, payout = idleShare = mulDiv(idle, shares, supply) = 1,000 (alice's fair token pro-rata of idle). But sBurn = _convertToShares(payout, Ceil) is priced against the OVERSTATED 22,000 NAV: sBurn = ceil(1,000e6 * (S+2^... offset) / (22,000e6+1)) = 0.909e18 shares — only 9.09% of alice's 10e18 stake. The honest-NAV-fair burn (against true 12,000) would be 1.667e18 (16.7%). Alice under-burns 0.758e18 shares and retains an oversized residual claim. Measured end-state (verified with FaultInjectingAdapter PoC + arithmetic): both holders were fair-worth 6,000 each; after alice's idle-only exit, bob's idle-only exit, and a later governance force-detach that recovers the adapter's real 10,000, alice ends with 6,372 total (1,000 cash + 5,372 residual) and bob with 6,152 — alice extracted ~372 (~6% of true remaining value) from bob purely by exiting first. The value leaks to whoever exits the idle branch earliest and to the last-standing residual holders unevenly. The C-1 guard's own regression test only asserts fairness for idle==0 (aGot==bGot==0); it does NOT bound this skew when idle>0, because the guard fixes the adapter-recall drain but leaves the idle payout burned against the loss-blind NAV.

**why_new(finder 申告)**:

> The C-1 guard (L213 + L379-381 + maxDeposit pause) is asserted to make the reverting-valuation exit 'idle-only ... fair idle distribution' and its regression (ExitSkewRevertFallbackC test_C_...guard_noFirstMoverDrain) only exercises idle==0, where the skew is vacuously 0. It never fixes the sBurn pricing: payout=idleShare is a correct token pro-rata, but sBurn=_convertToShares(payout,Ceil) still divides by the overstated loss-blind totalAssets(), so the exiter burns ~half the fair share count and keeps an inflated residual claim. This is a distinct, unhandled accounting defect (sBurn vs payout undercharge under the NEW valuation-unreadable branch), live whenever idle>0 — a realistic state via AdapterDepositFailed, force-detach partial recall, or shutdown recall — not the idle==0 case the guard closes.

**arbiter F 裁定根拠**:

> CONFIRMED by direct PoC on b835c09. In the C-1 revert branch _exitRealize pays payout=idleShare (correct token pro-rata) but computes sBurn=_convertToShares(payout,Ceil) (SIXXVault.sol:393), and _convertToShares divides by totalAssets()+1 (OZ ERC4626.sol:249), which in the catch branch degrades to the loss-blind, overstated idle+_totalDebt (SIXXVault.sol:198). With alice+bob 10k each, 4k idle, adapter loss to 5k, oracle reverting: alice(first) drew 2000 cash burning only ~1667/10000 shares (residual 8333); bob(last) then got 1090, not the fair 2000. This directly contradicts the guard's own regression assertion (ExitSkewRevertFallbackC.t.sol:71-90, 'the guard bounds it to the fair idle distribution'), which only exercises idle==0 (0/0). It also violates ADR-007's stated 柱4 invariant (007-pro-rata-exit-design.md D-1 step5 / D-2 row5: burn must be shares×pay/entitled at REALIZABLE price so per-share price stays equal and residual never dilutes later exiters) — the implementation burns at MARK price instead. Severity Medium not High: value is conserved (no mint), it requires a compound fault state (valuation reverting AND a realized loss making _totalDebt overstated AND idle>0), and it is the C-1 family which the project itself classes Medium (commit b835c09). But it IS a genuine, currently-live NEW defect the docs' resolution missed.

---

## RAW #2 — Lens B — 申告 [High] → 裁定 **KNOWN_MITIGATED**

**title**: C-1 guard does NOT close first-mover exit skew under a SILENT (non-reverting) overstated mark; emergency shutdown makes it directly reachable and lock-free

**location**: `src/core/SIXXVault.sol:339 _exitRealize (mark=activeAdapter.totalAssets() at L359, proRata L366, payout capped by realized fromAdapter L374-386); reachability via setEmergencyShutdown L655-703 (partial recall to idle + lock waiver at withdraw L159 / redeem L172).`

**exploit / PoC(finder 申告)**:

> The C-1 guard (_adapterValuationReadable / the try/catch in _exitRealize) only degrades to idle-only when adapter.totalAssets() REVERTS. When the adapter suffers a realized loss but its totalAssets() still returns a number (stale/overstated mark: realizable < mark, e.g. withdraw delivers 40% while _balance is unchanged), the guard's try SUCCEEDS, so the recall is priced against the overstated mark and the honest-partial-fill pays the first exiter their full mark-based pro-rata of the realizable pool while the loss-blind mark stays high. Concrete PoC (run, passing): 5 holders each deposit 10k (50k total); adapter set to deliver only 30% of any withdraw with totalAssets() reporting the stale full 50k (NO revert). Guardian calls setEmergencyShutdown(true): the recall reads mark=50k, withdraws, receives 15k idle (30%), adapter keeps 35k real; totalAssets() still over-reports. Shutdown WAIVES the withdraw lock (L159/L172), so all holders race to redeem in the same block. Sequential redeems yield 5100 / 4871 / 4631 / 4384 / 4133 -> the FIRST mover extracts ~5100 and the LAST ~4133 for identical 10k stakes: a ~23% ordering premium, monotonically decreasing with exit position. Two-holder variant: first gets 6400, last 5764 (~636 loss to the last-out). The victim is whoever exits last during the shutdown 'safe withdrawal' window; the extraction is bounded only by realizable-pool depletion, not by any code cap. No revert, no external donation, no attacker-controlled adapter beyond a realistic partial-delivery loss are required -- exactly the case Lens B flags: 'a silent realized-loss where totalAssets still returns a number.' The guard closes the reverting case only.

**why_new(finder 申告)**:

> The KNOWN C-1/D-1/E-1 item is paired with the KNOWN 'C-1 guard: _adapterValuationReadable -> idle-only + deposit pause' which is presented as the mitigation. This finding demonstrates the guard is INCOMPLETE: it is a pure try/catch on adapter.totalAssets() and therefore never engages for a silent overstated mark (non-reverting realized loss). Emergency shutdown independently (a) recalls only the delivered fraction to idle while leaving the mark overstated and (b) waives the withdraw lock, turning the still-live skew into a lock-free same-block race that any holder can lose by exiting last. This is the non-reverting branch the C-1 guard was believed to have handled but does not.

**arbiter F 裁定根拠**:

> The finder is correct that _adapterValuationReadable() (SIXXVault.sol:213-221) only returns false on a REVERT and never engages for a silent overstated mark — but this is exactly what the docs state and accept. The readable/silent-overstated-mark first-mover skew is the KNOWN-ACCEPTED residual: E1_EXIT_FAIRNESS_2026-07-13.md Case E measures the same shutdown-driven partial-recall race (10k/10k/10k/0/0), and 007-prefreeze-measurements.md §M-1 top + M-2 §147-152 and 007-pro-rata-exit-design.md D-5 §117-126 explicitly declare 'in-window the skew is UNBOUNDED for a convex/reverting adapter; the ONLY guarantee is governance force-detach' (ExitFairnessProdC 6.08×). The C-1 guard was scoped ONLY to the reverting case (commit b835c09) — it was never claimed to bound readable marks. Shutdown's lock-waiver is documented (H-4, SIXXVault.sol:278-288; maxWithdraw L281). This is a re-derivation of the accepted residual, bounded operationally by the depeg-mark-staleness runbook + force-detach, not a hole past the guard. KNOWN-ACCEPTED residual (in-window skew bounded only by force-detach).

---

## RAW #3 — Lens B — 申告 [Medium] → 裁定 **NEW_MEDIUM** (fix-needed)

**title**: Idle-only exit under a reverting adapter under-burns shares (sBurn priced against loss-blind _totalDebt), letting the first mover keep an oversized residual claim while taking full idle pro-rata

**location**: `src/core/SIXXVault.sol:393 sBurn=_convertToShares(payout, Ceil) using totalAssets() L186-204 which degrades to loss-blind _totalDebt (L198); combined with idleShare cap at L346 and payout at L386.`

**exploit / PoC(finder 申告)**:

> When adapter.totalAssets() REVERTS (C-1 guard active, idle-only), _exitRealize still computes sBurn = _convertToShares(payout) against totalAssets() which has degraded to the loss-blind _totalDebt (overstated, never marked down for the realized loss). PoC (run, passing): 2 holders (10k each, 20k shares), adapter realizes a 15k loss (real backing 5k), 4k idle present in the vault, then the oracle breaks (revertOnTotalAssets). totalAssets() degrades to idle 4k + _totalDebt 20k = 24k (vs true realizable 9k). Bob (first) redeems: idle-only caps his payout at idleShare = 4000*10000/20000 = 2000, but sBurn = convertToShares(2000) against the 24k loss-blind NAV burns only ~1666 of his 10000 shares -> he pockets 2000 cash AND retains ~8333 residual shares. Alice (last) then gets only 1090 from the depleted idle. So the first mover both drains a larger share of scarce idle and keeps a disproportionate residual claim on the adapter's remaining real backing. The payout cap works but the share-burn denominator is loss-blind, so the burn is decoupled from the cash and the residual claim is mispriced in the exiter's favour.

**why_new(finder 申告)**:

> The KNOWN C-1 guard is described as 'idle-only exit recall + deposit pause,' i.e. it constrains the RECALL/payout. This finding shows that even inside the idle-only path the SHARE ACCOUNTING (sBurn) is still priced against the loss-blind _totalDebt, so the guard does not make the idle-only exit fair when idle is present alongside a reverting valuation: the first exiter under-burns and keeps an oversized residual claim. Requires idle>0 during the revert window (e.g. from a prior partial recall / emergency-shutdown partial recall), so lower severity than finding 1, but it is a distinct accounting defect not addressed by the payout-side idle cap.

**arbiter F 裁定根拠**:

> Same defect as Lens A, independently confirmed. PoC-verified: sBurn=_convertToShares(payout) at SIXXVault.sol:393 prices against the loss-blind _totalDebt fallback (L198), so inside the C-1 idle-only path the first exiter under-burns and keeps an oversized residual while monopolizing scarce idle. The finder's numbers (2 holders, 15k loss, 4k idle → bob first pockets 2000 + retains ~8333 residual, alice gets 1090) reproduce exactly. Critically, this is NOT cured by force-detach (my extended PoC: after alice under-burns in-window then governance force-detaches recovering the real 5k, alice nets 5181 vs bob 3818 on a fair 4500 each — a PERMANENT ~682 transfer), so it escapes the docs' sole stated mitigation. This is one shared root cause with Lens A/C/D; fix once (burn at realizable price / block the idle-only exit-with-underburn, or write mark down before burning).

---

## RAW #4 — Lens C — 申告 [High] → 裁定 **NEW_MEDIUM** (fix-needed)

**title**: C-1 idle-only exit still lets the first exiter skim the idle buffer: idle payout burns shares at the overstated loss-blind price

**location**: `src/core/SIXXVault.sol:393 (_exitRealize sBurn) with L344-386 idle-only branch; totalAssets() L195-203 degrade-to-_totalDebt`

**exploit / PoC(finder 申告)**:

> Reachable state: two 10k holders, 40% of TVL carved to idle (idle=8,000), a realized adapter loss burns real backing down to 3,600, then the adapter's totalAssets() reverts (broken/not-ready oracle). Now _totalDebt=20,000 is loss-blind and totalAssets() degrades to idle+_totalDebt=28,000 (overstated). The C-1 guard makes the exit idle-only (fromAdapter=0), which the known PoC (test_C_revertFallback_guard_noFirstMoverDrain, idle==0) claims 'bounds it to the fair idle distribution'. It does NOT when idle>0: for a partial fill the code sets sBurn=_convertToShares(payout, Ceil) priced against the OVERSTATED degraded totalAssets, so each exiter under-burns shares for the real idle cash it takes and keeps an inflated residual claim. Measured end-to-end (foundry): alice (first) draws idleShare=4,000 cash burning only ~2,857e12 of her 10,000e12 shares; bob (last) then draws only 2,333 from the shrunken idle pool against his still-inflated share count. After governance force-detach recovers the real 3,600 and both redeem their residuals, alice nets 6,430 and bob 5,169 versus a fair 5,800 each on 11,600 distributable — a ~630 USDC (>10% of a fair share) transfer from the last exiter to the first, purely from exit ordering. Any holder who exits first during an unreadable-valuation window profits at the expense of those who exit later or wait for force-detach.

**why_new(finder 申告)**:

> The known C-1/D-1/E-1 finding and its guard PoC only cover idle==0 (0/0, 'neither drains') and conclude the guard restores fair idle distribution. That conclusion is false for idle>0: the guard zeroes the adapter RECALL but leaves the idle PAYOUT's sBurn priced against the loss-blind _totalDebt, so the first-mover skew re-enters through the burn-price channel the guard never touches. This is a live value leak in the newest C-1 code path, not the already-acknowledged adapter-pool drain.

**arbiter F 裁定根拠**:

> Same confirmed defect as Lens A/B/D, higher idle fraction (40% idle=8k). The finder correctly identifies that the C-1 guard zeroes the adapter RECALL but leaves the idle PAYOUT's sBurn (SIXXVault.sol:393) priced against the overstated degraded totalAssets() (L195-199), so first-mover skew re-enters via the burn-price channel the guard never touches, and force-detach does not restore fairness (finder measures alice 6430 vs bob 5169 vs fair 5800 — matching my PoC's permanent-skew-after-detach result). The finder rates it High; I rate the shared root cause NEW_MEDIUM (value-conserving, compound fault state required, C-1-family Medium classification) — but the substance is correct and fix-needed. Note the guard test (ExitSkewRevertFallbackC test_C_revertFallback_guard_noFirstMoverDrain) genuinely only covers idle==0, as the finder states.

---

## RAW #5 — Lens D — 申告 [High] → 裁定 **NEW_MEDIUM** (fix-needed)

**title**: C-1 guard leaves first-mover exit skew live whenever idle>0: idle-only exit under-burns shares against the inflated loss-blind totalAssets(), letting the first exiter monopolize idle and dilute later honest holders

**location**: `src/core/SIXXVault.sol:339 _exitRealize (sBurn at L393) + redeem requestedAssets at L173; C-1 guard L213/L359-381; totalAssets loss-blind fallback L195-199`

**exploit / PoC(finder 申告)**:

> Preconditions (all reachable): (a) the active adapter's totalAssets() reverts -> C-1 unreadable branch (fromAdapter stays 0, totalAssets() degrades to the loss-blind, OVER-reported _totalDebt at L198); (b) the adapter has suffered a REAL loss so _totalDebt over-states true NAV; (c) idle > 0 in the vault. Idle>0 with an unreadable adapter is reachable via a direct token donation to the vault, a prior _deployToAdapter failure (L438 catch leaves deposited funds idle: AdapterDepositFailed), or a partial emergency-shutdown/setAdapter recall.
> 
> Concrete numbers (USDC 6dp): Alice and Bob each deposit 10_000 while healthy (adapter=20k, _totalDebt=20k, supply=20000e9, idle=0). Adapter real backing collapses to ~0 and its oracle reverts (unreadable). 4_000 idle is present (donation / failed push). Now totalAssets()=idle(4000)+_totalDebt(20000)=24000 (real value is only the 4000 idle). Fair split of the 4000 idle is 2000/2000.
> 
> Alice (first) redeems all 10000e9 shares: idleShare=idle*shares/supply=2000, payout=min(requestedAssets,idleShare)=2000 (fair so far), BUT sBurn=_convertToShares(2000,Ceil) prices against the INFLATED TA=24000, giving only 1666e9 shares burned (~17% of her stake); she keeps 8333e9 residual shares (柱4). Bob (second, honest) then redeems all 10000e9: idle left=2000, but supply dropped by only 1666e9, so Bob's idleShare=2000*10000e9/(supply-1666e9)=1090; Bob's payout=1090. Result: Alice 2000, Bob 1090 -> Alice's first-mover monopoly gain = 910 (~45% skew) at Bob's expense, and after governance force-detach writes _totalDebt down, Alice's oversized residual claim keeps diluting Bob permanently. Root cause: the C-1 guard only stops pricing the RECALL against the stale mark; the SHARE BURN (sBurn, L393) and the redeem claim (convertToAssets, L173) still price against the same stale overstated totalAssets(), so the first exiter under-burns and monopolizes idle. The existing guard test (ExitSkewRevertFallbackC.t.sol::test_C_revertFallback_guard_noFirstMoverDrain) only proves the idle==0 case (asserts both get 0); it does not cover idle>0, where the skew is live.

**arbiter F 裁定根拠**:

> Same confirmed defect, the cleanest statement of it. The finder's arithmetic is exact and I reproduced it wei-for-wei: alice(first) idleShare=2000, sBurn=_convertToShares(2000) against inflated TA=24000 burns only ~1666e9/10000e9 shares (residual 8333e9); bob(second) idleShare=2000×10000e9/(supply−1666e9)=1090; alice gains 910 (~45% skew) at bob's expense (SIXXVault.sol:346 idleShare, :393 sBurn, :173 convertToAssets, :198 loss-blind fallback). Idle>0 with an unreadable adapter is reachable via costless direct token donation (verified) as well as AdapterDepositFailed (L438-442) / partial shutdown recall. Root cause correctly localized to the burn/claim pricing against the stale overstated totalAssets() that the guard does not touch. Shared root with A/B/C; NEW_MEDIUM, fix-needed.

---

## RAW #6 — Lens E — 申告 [High] → 裁定 **KNOWN_MITIGATED**

**title**: C-1 deposit pause is incomplete: `maxDeposit`/`maxMint` stay open under a readable-but-OVERSTATED (phantom) mark, letting a first-mover holder capture a fresh depositor's cash

**location**: `src/core/SIXXVault.sol:213-221 (_adapterValuationReadable), 261-274 (maxDeposit/maxMint), 339-396 (_exitRealize)`

**exploit / PoC(finder 申告)**:

> The C-1 guard's own comment (L206-212) states its job is to "pause deposits, so no depositor mints against a stale overstated mark." But `_adapterValuationReadable()` returns `false` ONLY when `adapter.totalAssets()` *reverts* (L216-220). A phantom/overstated mark (stale oracle, illiquid AMM, bad debt still reported at par) does NOT revert — it returns an inflated number — so the guard returns `true`, `maxDeposit`/`maxMint` return `type(uint256).max`, and `totalAssets()` reports the inflated mark. Concrete PoC (verified with PhantomMarkAdapter): setup Alice deposits 10,000 USDC; 30% pulled idle; adapter's real tokens halved via makePhantom while mark unchanged => idle 1,500 + realizable 5,000 = 6,500 real distributable, but reported totalAssets = 10,000. `vault.maxDeposit(Bob)` returns uint256.max (NOT paused). Bob deposits 10,000 real USDC, minting against the 10k inflated NAV. Alice redeems FIRST: `_exitRealize` recalls her pro-rata of the *overstated* mark and pays her the full 10,000 (funded partly by Bob's fresh cash). Bob redeems SECOND and gets only 6,500 plus worthless residual shares. Net: Alice extracted 10,000 for a stake really backed by 6,500 (+3,500), the 3,500 coming directly out of Bob's deposit. The known C-1/E-1 exit-skew finding covers ordering skew among *existing* holders; the NEW, still-live gap is the DEPOSIT ingress under a phantom mark that the guard is documented to block but does not, because it only detects reverts, not overstatement.

**why_new(finder 申告)**:

> Known C-1 finding is scoped to a reverting/loss-blind mark on the EXIT path; the guard already handles reverts. This is the deposit side under a NON-reverting overstated mark, which bypasses `_adapterValuationReadable()` entirely (no catch taken) and directly contradicts the guard's stated purpose (L211-212 "no depositor mints ... against a stale overstated mark"). maxDeposit returned uint256.max in the PoC while real backing was 65% of reported NAV.

**arbiter F 裁定根拠**:

> The mechanism is real: _adapterValuationReadable() (SIXXVault.sol:216-220) returns false ONLY on a revert, so under a silent phantom/overstated mark maxDeposit/maxMint (L267/L272) return uint256.max and a fresh depositor mints against inflated NAV, then is diluted by earlier exiters. But this is the KNOWN-ACCEPTED Class-P overstated-mark residual (007-prefreeze-measurements.md M-2 §123-152: Ethena/Pendle depeg mark overstates realizable, bounded only by depeg-depth × force-detach latency; runbook M-3). Deposit-time dilution is an inherent consequence of any oracle NAV during that same accepted window, not a new hole past the guard — the guard was never claimed to bound the readable case. One valid LOW_INFO sub-point: the guard comment (L211-212) reads as if it blocks depositors 'minting against a stale overstated mark' generally, when it only catches reverts; that comment should be tightened to say 'unreadable/reverting' only. The underlying economic exposure is the accepted residual, mitigated operationally.

---

## RAW #7 — Lens E — 申告 [Medium] → 裁定 **KNOWN_MITIGATED**

**title**: First-mover exit skew under a readable phantom mark is unbounded and not code-bounded (only governance force-detach mitigates)

**location**: `src/core/SIXXVault.sol:359-386 (_exitRealize wantAdapter=min(proRata,need) prices recall against the overstated mark)`

**exploit / PoC(finder 申告)**:

> With mark 35,000 / realizable 17,500 / idle 15,000 across 5 equal holders (verified via ExitFairnessProdC): the recall cap `proRata = mulDiv(mark, shares, supply)` uses the OVERSTATED mark, so each successive exiter's cap stays high while realizable liquidity drains. Measured payouts in exit order: 10,000 / 10,000 / 6,500 / 2,553 / 1,646 (max/min 6.08x), vs fair pro-rata 6,500 each. The first two exiters take their full mark claim, stranding the tail on residual shares against phantom value. Because `_adapterValuationReadable()` only fires on reverts, the C-1 idle-only fallback never engages here — the recall keeps pricing against the phantom mark. An exiter who front-runs a mass exit (or any holder who simply exits first when an oracle goes stale-high) extracts value from later exiters.

**why_new(finder 申告)**:

> Reported as the still-live behavior of the C-1 family under a readable overstated mark (the C-1 guard demonstrably does NOT bound it — it only catches reverts). Flagged as Medium because the codebase's own test comments already acknowledge it is "bounded only by governance force-detach," i.e. accepted-but-unmitigated in-code; included for completeness since the C-1 guard does not close it.

**arbiter F 裁定根拠**:

> This is verbatim the KNOWN-ACCEPTED residual and the finder self-flags it as such ('Medium... included for completeness since the C-1 guard does not close it'). wantAdapter=min(proRata,need) with proRata=mulDiv(mark,shares,supply) prices the recall against the readable overstated mark (SIXXVault.sol:359-368); the docs measure exactly this (ExitFairnessProdC 6.08×; I2_PRORATA §27-41) and 007-pro-rata-exit-design.md D-5 §117-126 + 007-prefreeze-measurements.md §M-1/M-2 declare it UNBOUNDED in-window, bounded ONLY by governance force-detach + the depeg-mark-staleness runbook. The C-1 guard was explicitly scoped to reverts only and never claimed to close this. KNOWN-ACCEPTED residual (in-window readable-mark skew bounded only by force-detach).

---

## arbiter F 総括

> I verified every finding against the code at b835c09 and reproduced the disputed mechanisms with a foundry PoC using FaultInjectingAdapter.
> 
> THE ONE REAL NEW DEFECT (findings A, C, D, and Lens-B finding #3 — four finders converging on ONE root cause): In the C-1 idle-only revert branch, _exitRealize pays a correct idle pro-rata (payout=idleShare) but computes sBurn=_convertToShares(payout,Ceil) (SIXXVault.sol:393), which divides by totalAssets()+1 — and in the catch branch totalAssets() has degraded to the loss-blind, OVERSTATED idle+_totalDebt (L198). So the first exiter UNDER-BURNS: my PoC (2 holders 10k each, 4k idle, adapter loss to 5k, oracle reverting) shows alice draws 2000 cash burning only ~1667/10000 shares (residual 8333), then bob(last) gets 1090 not the fair 2000 — first/last skew 1.83×. Crucially this is a PERMANENT transfer that the docs' sole stated mitigation does NOT cure: after alice under-burns in-window then governance force-detaches (recovering the real 5k), alice nets 5181 vs bob 3818 on a fair 4500 each (~682 USDC / ~15% permanently skimmed). This defeats the guard's own regression claim (ExitSkewRevertFallbackC only asserts fairness at idle==0) and violates ADR-007's own 柱4 invariant (007-pro-rata-exit-design.md D-1/D-2/D-3: burn must be at REALIZABLE price shares×pay/entitled so per-share price stays equal — the code burns at MARK price). Reachable via costless direct donation, AdapterDepositFailed, or partial shutdown recall. I rule it NEW_MEDIUM (value-conserving, compound fault state, consistent with the project's own C-1-family Medium classification) and fix-needed before freeze. Fix once at the sBurn/claim pricing (e.g. write the mark down / block the under-burning idle-only exit / burn at realizable price).
> 
> EVERYTHING ELSE IS KNOWN-ACCEPTED: Lens B (silent readable overstated mark + shutdown lock-free race), Lens E-1 (phantom-mark deposit ingress), and Lens E-2 (readable phantom-mark exit skew) are all the readable-overstated-mark residual that the docs explicitly accept as 'UNBOUNDED in-window, bounded ONLY by governance force-detach + runbook' (007-prefreeze-measurements M-1/M-2, 007-pro-rata-exit-design D-5, E1 Case E). The C-1 guard was scoped only to REVERTS and was never claimed to bound the readable case, so these are re-derivations of the accepted residual, not holes past the guard. One LOW_INFO cleanup: the guard comment (SIXXVault.sol:211-212) overstates its reach ('no depositor mints against a stale overstated mark') when it only catches reverts — tighten to 'unreadable/reverting'.

## LOW_INFO(arbiter 指摘)— guard コメントの reach 誇張

arbiter 総括の指摘:`_adapterValuationReadable` のコメント(旧 SIXXVault.sol:211-212)が「no depositor mints against a
stale overstated mark」と reach を誇張していた(実際は **revert(unreadable)しか捕捉しない**。readable-but-overstated
= phantom mark は捕捉しない=それが KNOWN_MITIGATED 残余)。→ コメントを「unreadable/reverting」に厳密化(本修正で対応)。

---

## 凍結前確認① — (0,0) idle-only-freeze は攻撃者に誘発可能か → **誘発不能**

F guard は `adapter.totalAssets()` が **revert する(valuation unreadable)** ときのみ (0,0) を返す。攻撃者がこの状態を
故意に作れれば「全単独 exit を force-detach まで 0 に凍結する grief」になり得るため、shipped adapter 全数の
`totalAssets()` revert 誘発性を精査した。

**全 shipped adapter の `totalAssets()` は、adapter 自身の保有残高に対する引数なし外部 view のみで構成**:

| adapter | totalAssets() の外部呼び出し | 攻撃者引数 | revert 条件 | 誘発性 |
|---|---|---|---|---|
| AaveV3USDCAdapter | `aToken.balanceOf(this)` | なし | scaledBalance×index、revert しない | **不能** |
| VenusUSDTAdapter | `vToken.balanceOf(this) * vToken.exchangeRateStored()` | なし | 純 storage 読み・revert しない | **不能** |
| EthenaSUSDeAdapter | `susde.balanceOf(this)` → `susde.convertToAssets(shares)` | なし | sUSDe totalSupply==0 のみ(保有時は不成立) | **不能** |
| PendlePTAdapter | pre-expiry: `ptOracle.getPtToAssetRate(market, twapDuration)`(post-expiry は 1e18 定数) | なし | TWAP not-ready / Pendle 障害 | **不能**(注) |

- どの経路も **caller/attacker のパラメータを一切取らない**(adapter 自身の token 残高を読むのみ)。
- Aave/Venus/Ethena は revert しない純 view。**外部プロトコルの真の障害**(protocol pause・upgrade バグ)でのみ revert し得るが、
  vault ユーザー操作からは到達不能。
- (注)Pendle のみ外部 TWAP オラクルを呼ぶが、`market`/`twapDuration` は **immutable(construct 時固定)**・
  deploy 時に ready 検証済・oracle cardinality は単調増加(一度 ready なら ready 維持)。post-expiry は定数 1e18。
  ∴ **攻撃者は市場スワップでも TWAP を revert させられない**(価格を動かすだけで revert しない。TWAP は操作耐性)。
- donation/残高操作は totalAssets を**増やす**方向で revert させない。exit は `nonReentrant`。

**結論**:(0,0) 状態は **攻撃者に誘発不能**。発生源は Pendle TWAP not-ready / 各プロトコルの真の外部障害のみで、
いずれも vault ユーザー操作から到達できない。さらに万一(外部障害で)発生しても、guard は設計上 **skim=0**(攻撃者利得 0)・
全単独 exiter に対称・被害者を標的化不能・governance force-detach で解消 ⇒ **利益ある/標的化可能な grief 経路にはならない**
(mis-price するより 0 を払う fail-safe)。この根拠を `_exitRealize` の F guard コメントにも 1 行で明記。
