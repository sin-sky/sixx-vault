# Runbook — stale / overstated adapter mark → force-detach (ADR-007 residual defense)

> **Purpose.** ADR-007 exits never revert and never strand anyone (柱1), but under a *persistently
> overstated* adapter mark an early exiter can realize up to **e ≈ 2.72×** the cash a same-size late
> exiter realizes *within that window* (bounded — see `docs/architecture/designs/007-prefreeze-measurements.md`
> M-1). The burn-price layer deliberately does **not** fix this (SHIN 2026-07-13: mark-price burn kept;
> realizable-price burn rejected — attacker-inducible + breaks 柱4). The **true defense is operational**:
> detect a persistently-overstated mark and `force-detach` fast. This runbook is that procedure.
>
> Satisfies mainnet-gate **G3** ("デペグ runbook が運用手順書に存在"). Owner: guardian (2-of-3 Safe) + governance.

---

## 1. Which marks can persistently overstate (from M-2)

| Class | Adapters | Cause | Self-corrects? | Action |
|---|---|---|---|---|
| **L — liquidity** | Aave USDC, Venus USDT | money-market utilization → 100%, no cash to redeem | **Yes** — rate curve pulls liquidity back (minutes–hours); residual shares recover full value on thaw (柱4) | monitor; force-detach only if frozen/bad-debt persists |
| **P — peg-blind** | Ethena sUSDe, Pendle PT | `convertToAssets` / par-cap blind to a USDe/sUSDe **depeg** beyond the built-in buffer (Ethena ≤3%, Pendle TWAP+par-cap) | **No** — persists for the depeg duration | **force-detach** once depeg is confirmed > buffer and expected to persist |

Class L is handled fairly by the residual-share design and needs no urgent action. **This runbook's
trigger is Class P.**

## 2. Detection — signals & thresholds

Run all three continuously; **Class P alert = (A peg breach) AND (B under-delivery)**. C is corroborating.

**A. Peg feed (primary, off-chain).** Track USDe/USDC on a liquid venue (Curve USDe/USDC + crvUSD
route spot, and/or a Chainlink USDe/USD feed if live).
- **WARN** at deviation ≥ **1.0%** below par (≈ ½ of Ethena's 3% buffer).
- **ACT** at deviation ≥ **2.5%** below par *and still falling / sustained > 30 min* (approaching the 3%
  buffer, beyond which adapter exit floors start reverting).

**B. On-chain under-delivery (primary, from emitted events).** Index the adapter `Withdrawn(assets,
withdrawn, recipient)` event.
- **WARN** when `withdrawn < assets × 0.99` on any real recall.
- **ACT** when `withdrawn < assets × 0.97` (short by more than the 3% buffer) on ≥ 2 recalls, OR the
  adapter `withdraw` starts reverting (caught by the vault as `fromAdapter = 0`; visible as vault
  `Withdraw(..., payout, sBurn)` where `payout` collapses toward the caller's idle pro-rata).

**C. Mark-vs-realizable spread (corroborating, on-chain read).** Periodically compare the adapter's
reported `totalAssets()` against a realizable quote:
- Ethena: `convertToAssets(bal)·(1−slippageBps)` vs the Curve exit-route quote for the same sUSDe.
- Pendle: `min(TWAP, 1e18)·ptBal` vs a `swapExactPtForToken` static-call quote (spot).
- **ACT** when reported mark exceeds the realizable quote by > **3%** (buffer) for > 30 min.

> **Class L vs P discriminator:** if B fires but A shows peg **at par**, it is Class-L illiquidity —
> do **not** force-detach; monitor for thaw. Force-detach only when the **peg itself** (A / C) is
> breached beyond the buffer.

## 3. Action — force-detach procedure

Target latency budget: **ACT signal → force-detach executed within 30 minutes** (this bounds the M-2
overstatement window; the resulting skew is already bounded by e per M-1).

1. **Freeze new entries** so nobody deposits at the overstated mark: guardian
   `vault.setEmergencyShutdown(true)` (immediate; `maxDeposit/maxMint → 0`). Exits stay open (柱1).
2. **(Ethena, optional shallow case only)** if the depeg is < 3%, governance may
   `EthenaSUSDeAdapter.setSlippageBps(newBps)` up to `MAX_SLIPPAGE_BPS = 300` to write the mark down
   honestly (do this **paused**, per mainnet-gate G3/F-2, to avoid a NAV-step arbitrage). This lever
   is **insufficient for a deep (> 3%) depeg** — go to step 3.
3. **Force-detach:** governance `vault.setAdapter(address(0))`. This recalls best-effort from the
   adapter and **writes the mark down to realizable**, after which all remaining exits are at the same
   honest (lower) NAV — flat payouts (verified: `test/ExitFairnessE1.t.sol::test_E1_D_forceDetach_thenExit`).
   `setAdapter(address(0))` bypasses the registry whitelist (H-1) and is wrapped in try/catch so a
   frozen adapter cannot brick the detach.
4. **Confirm** `vault.totalAssets()` dropped to the realizable level and `activeAdapter == address(0)`.
   Residual shares held by early exiters now redeem at this honest NAV (no further skew).
5. **Recovery:** once the peg recovers and the adapter is healthy, re-attach via the normal
   registry-gated `setAdapter` path and lift shutdown. Residual-share holders who did not fully exit
   recover value at the recovered NAV (柱4).

## 4. Key holders

- `setEmergencyShutdown` — **guardian** (per-chain 2-of-3 Gnosis Safe).
- `setAdapter(address(0))` / `setSlippageBps` — **governance** (TimelockController). NOTE: a 48h
  timelock delay on `setAdapter` would blunt an emergency detach; confirm the **guardian shutdown
  (step 1) is the immediate stopgap** and that governance has an expedited/emergency path for the
  detach, or pre-stage the detach transaction. → tracked as an open ops-infra item.

## 5. Open items (ops-infra, not code)

- [ ] Stand up the live monitors A/B/C (peg feed subscription, `Withdrawn` event indexer, periodic
      mark-vs-quote reader) with the WARN/ACT thresholds above and paging to the guardian Safe signers.
- [ ] Confirm/define governance's expedited force-detach path vs the 48h timelock (pre-staged tx or
      guardian-scoped detach), so step 3 meets the 30-min latency budget.
