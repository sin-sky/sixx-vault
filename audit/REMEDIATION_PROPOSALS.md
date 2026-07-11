# REMEDIATION PROPOSALS — SIXX Vault（Part B）

> 出自：`THREAT_COUNCIL_REMAINING_2026-07-11.md`（②③④⑦⑧ 合議）。**新規 HIGH/MEDIUM 実バグは無し**＝以下は全て LOW / informational（資金喪失リスクなし）。
>
> **✅ 2026-07-11 SHIN 承認・実装反映済**：**P1 / P2 / P4 実装**、**P3 実装**（Pendle in-scope）、**P5 は本番前運用ゲートとして据え置き**。各項「状態」参照。ハードニング最終形として再凍結（新 tip）→ `make-handoff.sh` で束再生成。

---

## P1. RD5 — zero-share deposit の dust 拒否（LOW）

**現象**：price-per-share が高い状態で極小 deposit を行うと、`shares` が 0 に floor されつつ資産（≤ 入金額の dust）が pool へ移る。OZ v5 ERC-4626 は `shares > 0` を強制しない標準挙動。
**影響**：自己負担 dust に限定・第三者搾取不能・他 holder 無害・非 insolvency。＝資金喪失リスクではなく監査 nit。
**適用差分**：`SIXXVault.deposit`（`super.deposit` 戻り値）と `mint`（入力 shares）に `require(shares > 0, "VAULT: zero shares")`。
**behavior 影響**：極小入金が revert に変わる（UX 無害＝そもそも 0 share）。

**状態：✅ 実装済（2026-07-11）** — PoC＝`test/RemediationPartB.t.sol::test_P1_*`＋`ThreatCouncilRemaining::test_RD5_zeroShareDeposit_nowReverts`。

---

## P2. AC8 — 特権変更の event 追加（LOW・可観測性）

**現象**：`setManagementFee`（SIXXVault）と `proposeGovernance`/`acceptGovernance`（AdapterRegistry）が event 未発火。
**適用差分**：`ISIXXVault` に `ManagementFeeUpdated(oldFee,newFee)`／`IAdapterRegistry` に `GovernanceProposed(current,pending)`・`GovernanceAccepted(newGovernance)` を追加し各所で emit。
**behavior 影響**：なし（event 追加のみ・状態遷移不変・ABI 互換）。
**注**：`setPerformanceFee` は P4 で not-implemented revert 化＝無音の状態遷移が存在しないため event 不要（当初案の `PerformanceFeeUpdated` は未採用）。

**状態：✅ 実装済（2026-07-11）** — PoC＝`test/RemediationPartB.t.sol::test_P2_*`。

---

## P3. OR2 / ⑤ — Pendle twapDuration 下限強制（LOW・継続）

**現象**：`PendlePTAdapter` の `twapDuration`（immutable）は constructor で `require(twapDuration_ > 0)` のみ。過小 TWAP 窓は理論上マニピュレーション耐性を下げる（実運用は deploy 時 `getOracleState` readiness と immutable で緩和済）。
**適用差分**：`require(twapDuration_ > 0)` → `require(twapDuration_ >= 900, "ADAPTER: twap < 15min")`（最短 15 分 TWAP）。
**behavior 影響**：過短窓の新規デプロイのみ revert（既存デプロイは immutable ゆえ無関係・fork テストは `TWAP=900` で無影響）。

**状態：✅ 実装済（2026-07-11・Pendle in-scope）** — PoC＝`test/RemediationPartB.t.sol::test_P3_pendle_rejectsTwapBelow15min`。

---

## P4. ⑥ — performanceFee dead-code の明示化（informational・継続）

**現象**：`performanceFee` は settable（旧 cap 30%）だが accrual 経路で未使用（現状 management fee のみ収集）。
**適用差分（(a) 採用）**：`setPerformanceFee` を `require(newFee == 0, "VAULT: performance fee not implemented")` 化（`0` は harness/tooling 正規化用に no-op 許容）。`MAX_PERFORMANCE_FEE` 定数は撤去。
**behavior 影響**：nonzero 設定が revert（未使用ゆえ実害なし）。`setPerformanceFee(0)` は許容ゆえ echidna/invariant/halmos の setup 無影響。
**別トラック**：(b) performance fee accrual 実装は新機能＝収益設計（memory: SIXX revenue strategy Phase 3）と併せ別ラウンド。

**状態：✅ 実装済 (a)（2026-07-11）** — PoC＝`test/RemediationPartB.t.sol::test_P4_*`＋`SIXXVault.t.sol::test_setPerformanceFee_notImplemented_rejectsNonzero`。

---

## P5. AC4 — 本番 governance/guardian の Timelock+Safe 強制（ops・据え置き）

**現象**：単一 EOA governance の本番運用は禁止（`PRE_AUDIT_HARDENING` C-1・deploy script は EOA gov で revert 済）。
**影響**：単一鍵漏洩時、gov は registry 登録済 adapter への切替＋（register 権限で）悪意 adapter 登録が可能＝AC10 の registry 信頼前提。Timelock 48h が唯一の検知窓。
**運用ゲート（コード改修不要）**：mainnet デプロイは governance=TimelockController(48h)・guardian=各チェーン 2-of-3 Safe を必須。registry の `registerAdapter` も Timelock 配下（gov=Timelock なら自動 48h 遅延）。

**状態：⏸ 据え置き（本番前運用ゲート）** — コード改修不要。mainnet 反映ゲート `docs/operations/mainnet-gate.md` に P5 として明記。SHIN 承認済＝本番デプロイ時に強制。

---

## まとめ

| # | 項目 | 深刻度 | behavior 変更 | 状態 |
|---|---|---|---|---|
| P1 | RD5 zero-share 拒否 | LOW | 有（極小入金 revert） | ✅ 実装済 |
| P2 | AC8 event 追加 | LOW | 無 | ✅ 実装済 |
| P3 | OR2 twapDuration 下限 | LOW | 有（過短窓デプロイのみ） | ✅ 実装済 |
| P4 | ⑥ performanceFee 明示化 | info | 有（nonzero revert） | ✅ 実装済 (a) |
| P5 | AC4 Timelock+Safe 強制 | ops | 無（運用ゲート） | ⏸ 本番前ゲート |

> P1-P4 は SHIN 承認済＝ハードニング最終形として main へマージ・再凍結。P5 は本番デプロイ時ゲート。
