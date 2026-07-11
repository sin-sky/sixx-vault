# REMEDIATION PROPOSALS — SIXX Vault（Part B・提案のみ・マージ禁止）

> **本書は提案のみ。凍結コード `68eb3ec` には一切変更を入れない。** behavior 変更を伴うため SHIN 承認まで凍結。
> 出自：`THREAT_COUNCIL_REMAINING_2026-07-11.md`（②③④⑦⑧ 合議）。**新規 HIGH/MEDIUM 実バグは無し**＝以下は全て LOW / informational（資金喪失リスクなし・是正は任意）。
> 承認された項目のみ、ハードニング最終形（外部監査前）に織り込み → 再凍結して提出。

---

## P1. RD5 — zero-share deposit の dust 拒否（LOW）

**現象**：price-per-share が高い状態で極小 deposit を行うと、`shares` が 0 に floor されつつ資産（≤ 入金額の dust）が pool へ移る。OZ v5 ERC-4626 は `shares > 0` を強制しない標準挙動。
**影響**：自己負担 dust に限定・第三者搾取不能・他 holder 無害・非 insolvency（PoC `test_RD5_zeroShareDeposit_isBoundedSelfInflictedDust` で bound 実証）。＝**資金喪失リスクではなく監査 nit**。
**提案差分（案・未適用）**：
```solidity
// SIXXVault.deposit / mint（super 呼出の戻り値に対して）
uint256 shares = super.deposit(assets, receiver);
require(shares > 0, "VAULT: zero shares");   // dust 入金を明示 revert
return shares;
```
**behavior 影響**：極小入金が revert に変わる（UX 上は無害＝そもそも 0 share）。既存テストへの影響：dust を意図する箇所のみ。
**代替**：OZ 標準挙動として受容し、フロントで min-deposit を課す（コード無改変）。
**推奨**：フロント min-deposit で足りるなら受容可。オンチェーン厳格化を望むなら P1 適用。

---

## P2. AC8 — 特権変更の event 追加（LOW・可観測性）

**現象**：`setPerformanceFee` / `setManagementFee`（SIXXVault）と `proposeGovernance`/`acceptGovernance`（AdapterRegistry）が event を発火しない。他の特権アクションは発火済。
**影響**：オフチェーン監視／インシデント追跡の穴（資金安全性には無関係）。
**提案差分（案・未適用）**：
```solidity
// ISIXXVault に追加
event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
event ManagementFeeUpdated(uint256 oldFee, uint256 newFee);
// IAdapterRegistry に追加
event GovernanceProposed(address indexed current, address indexed pending);
event GovernanceAccepted(address indexed newGovernance);
// 各 setter / transfer 関数末尾で emit
```
**behavior 影響**：なし（event 追加のみ・状態遷移不変）。ABI へ event 追加＝互換。
**推奨**：適用（低コスト・監視強化）。

---

## P3. OR2 / ⑤ — Pendle twapDuration 下限強制（LOW・継続）

**現象**：`PendlePTAdapter` の `twapDuration`（immutable）は constructor で `require(twapDuration_ > 0)` のみ。過小な TWAP 窓は理論上マニピュレーション耐性を下げる（実運用は deploy 時 `getOracleState` readiness と immutable で緩和済）。
**影響**：会計マークが過短 TWAP になりうる（現行 deploy は健全値を設定済＝実害なし）。prior council ⑤ の継続項目。
**提案差分（案・未適用）**：
```solidity
// PendlePTAdapter constructor
require(twapDuration_ >= 900, "ADAPTER: twap < 15min");   // 最短 15 分 TWAP
```
**behavior 影響**：過短窓の新規デプロイのみ revert（既存デプロイは immutable ゆえ無関係）。
**推奨**：次期 Pendle adapter 改訂（M-4 rotation）時に同梱。

---

## P4. ⑥ — performanceFee dead-code の明示化（informational・継続）

**現象**：`performanceFee` は settable（`setPerformanceFee`・cap 30%）だが accrual 経路で未使用（現状 management fee のみ収集）。`AUDIT_PACKAGE §5` に既記。
**影響**：レビュアーの混乱・将来の未配線リスク（現状は無害）。
**提案（案・未適用）**：以下いずれか。
- (a) `setPerformanceFee` を `revert("VAULT: performance fee not implemented")` にする（機能を明示的に無効化）。
- (b) performance fee accrual を実装（harvest 時の利益に対し課金）＝**新機能＝別ラウンド・要設計/監査**。
**behavior 影響**：(a) は setter が revert に変わる（未使用ゆえ実害なし）／(b) は新機能。
**推奨**：短期は (a)。(b) は収益設計（memory: SIXX revenue strategy Phase 3）と併せ別トラック。

---

## P5. AC4 — 本番 governance/guardian の Timelock+Safe 強制（ops・再確認）

**現象**：単一 EOA governance の本番運用は禁止（`PRE_AUDIT_HARDENING` C-1・deploy script は EOA gov で revert 済）。
**影響**：単一鍵漏洩時、gov は **registry 登録済** adapter への切替＋（register 権限で）悪意 adapter 登録が可能＝AC10 の registry 信頼前提。Timelock 48h が唯一の検知窓。
**提案（コード改修不要・運用ゲート）**：
- mainnet デプロイは governance=TimelockController(48h)・guardian=各チェーン 2-of-3 Safe を必須（既存 gate の再掲・逸脱時デプロイ禁止）。
- registry の `registerAdapter` も Timelock 配下に置く（gov=Timelock なら自動的に 48h 遅延）。
**推奨**：既定方針の再確認（`THREAT_COUNCIL_2026-07-11` 運用規約 4 と一致）。

---

## まとめ

| # | 項目 | 深刻度 | behavior 変更 | 推奨 |
|---|---|---|---|---|
| P1 | RD5 zero-share 拒否 | LOW | 有（極小入金 revert） | 任意（front min-deposit で代替可） |
| P2 | AC8 event 追加 | LOW | 無 | 適用推奨 |
| P3 | OR2 twapDuration 下限 | LOW | 有（過短窓デプロイのみ） | 次期 adapter 改訂で同梱 |
| P4 | ⑥ performanceFee 明示化 | info | 有(a)/新機能(b) | 短期 (a) |
| P5 | AC4 Timelock+Safe 強制 | ops | 無（運用ゲート） | 既定再確認 |

> **全て凍結コード外。SHIN が承認した項目のみ最終ハードニングに反映 → 再凍結。**
