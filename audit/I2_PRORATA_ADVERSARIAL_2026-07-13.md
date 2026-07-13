# I-2 — 敵対的リパス: pro-rata 退出実装（design c・working-tree 未コミット差分）

> **未凍結・未マージ。GO 前の勝手な再凍結・マージ・タグ禁止(SHIN)を厳守。** 本書は I-2 の測定結果と
> 是正提案のみ。実装差分（`src/core/SIXXVault.sol` の `_exitRealize`/`_completeExit`）は working-tree に
> 存在するが **未コミット**。R8-1 の教訓に従い、差分を「未監査の新規コード」として叩いた結果を数値で確定する。
>
> 証拠 PoC: `test/ExitFairnessProdC.t.sol`（新規）+ `test/mocks/PhantomMarkAdapter.sol`（新規）。
> 既存バッテリの回帰: 非fork 27スイート中、13 fail（内訳は §5）。

---

## 結論(先出し)

- **I-1 実装は working-tree に既存**（`_exitRealize` 中核）。柱1(no revert)/柱4(residual share) は honest/throttle
  ケースで達成。A6(shutdown 手数料免除)は既存 `_collectFees` の `if (emergencyShutdown) return 0;` で達成。
- **ただし SHIN の GO 前提「価値の公平(全員 6,500 均等)は (c) で達成済み」は、実装では成立しない**
  — **mark が realizable を過大表示する局面(realizable<mark、E1 が危険と名指しした regime)で、先着 2 名が
  face 満額 10,000 を抜き、残余がスクラップになる（F-1）。** 実測（下記）で確定。
- 加えて **H-02 回帰(F-2)**・**over-recall で idle 滞留=非カストディ破れ(F-3)**・**revert selector 変更(F-4)** を確認。

---

## F-1 (High) — 過大 mark 局面で design (c) の「価値の公平」が実装で達成されない

### 再現(実 vault・`test_prodC_phantomMark_5userRun`)

モデル: TVL 50,000 / idle 15,000 / adapter mark 35,000 だが **realizable(実引出可能トークン)=17,500**
（残り 17,500 は phantom=不実現の bad debt/stale mark）。同一 share 5 人が順に全額 redeem。

実測 cash（退出順）:

| 退出順 | cash | 焼却 share | residual share | 設計 (c) が約束した値 |
|---|---:|---|---|---:|
| 1 | **10,000** | 全焼却 | 0 | 6,500 |
| 2 | **10,000** | 全焼却 | 0 | 6,500 |
| 3 | 6,500 | 部分 | 3.5e18 | 6,500 |
| 4 | 2,553 | 部分 | 7.45e18 | 6,500 |
| 5 | 1,645 | 部分 | 8.35e18 | 6,500 |

- **max/min = 6.08×**。実配布価値 32,500(=idle15k+realizable17.5k)の公平分 6,500 に対し、先着 2 名が
  **各 +3,500 の実価値を超過抽出**。抜けた 2 名は全 share 焼却済み＝**residual で後から均霑されない**（永久に不公平）。
- 対照 `test_prodC_honestMark_fullLiquidity_control` は 10,000×5（honest mark・完全流動性なら公平）→ **問題は
  「mark>realizable」局面に限定**。だがそれは E1 §1 が「柱1/柱3 の主戦場」と特定した現実的局面（PT 満期前・
  Ethena デペグ・薄 AMM・stale oracle）。

### 根本原因(src 精読)

`_exitRealize` は **recall 量を「過大 mark の pro-rata」= `wantAdapter = mulDiv(mark, shares, supply)`** で決め、
支払を `min(requested, idleShare + 実受領)` にクランプする。D-2 モデル (c)（`_designC`）は
`entitled = shares × (idle + realizable)/supply` で **realizable ベース**にクランプしたため 6,500×5 になった。
**実装は realizable を観測できず mark を代用**するため、先着は自分の mark-pro-rata(=過大)を丸取りし、
共有 realizable バッファを枯らす。

### なぜ「小さな差分」で直せない可能性が高いか(要 SHIN 判断)

realizable は **view で事前算定不能**（実 recall しないと分からない。先着 caller の probe は満額返るため
希少性を検知できない）。自動 on-chain で公平化するには原理的に:
1. **withdrawal queue / batch**（同一窓の請求者に entitlement 同一比率を配る）— **SHIN が「新規キュー不可」と決定済**、または
2. **exit 前に mark を realizable へ writedown**（= 既存の governance `setAdapter(address(0))` force-detach。E1 Case D で
   6,500×5 に収束。ただし**手動**）。

→ **実装は「honest/保守 mark なら公平・過大 mark なら先着(force-detach で救済)」**。これは status quo からの
改善(柱1 で revert 消滅・tail も部分 cash)だが、**GO 前提の「自動で価値公平」には未達**。
**SHIN 決定要求**: (A) 「adapter mark は保守(≤realizable)を前提、過大 mark は force-detach 運用で吸収」と
明文化し公平主張を条件付きに訂正して受容するか、(B) 何らかの queue/socialization を再検討するか。

---

## F-2 (High) — H-02 回帰: `totalAssets()` revert で recall が 0 になり資金が stuck（柱1 破れ）

`test_H02_recall_fallsBack_whenTotalAssetsReverts_noShutdown` が fail。

`_exitRealize`:
```solidity
try IStrategyAdapter(activeAdapter).totalAssets() returns (uint256 a) { mark = a; } catch { mark = 0; }
uint256 wantAdapter = supply == 0 ? 0 : Math.mulDiv(mark, shares, supply); // catch→mark0→wantAdapter0
```
adapter の valuation が revert(壊れた oracle / not-ready TWAP)だと **mark=0 → wantAdapter=0 → recall を一切
試みない** → withdraw() は生きているのに **adapter 資金が引き出せず全額 stuck**。旧 `_recallFromAdapter` は
catch 時に `needed` を best-effort pull していた（H-02 の趣旨）。**柱1 を revert 以外の形で破る回帰。**

**是正案(小差分)**: catch 時に mark を `_totalDebt` へ degrade（vault 自身の `totalAssets()` と同じ縮退則）し、
その pro-rata で best-effort recall。実受領デルタで会計するため過剰 pull にはならない。

---

## F-3 (Medium) — over-recall で idle 滞留（INV-3 非カストディ破れ）

`SIXXVaultInvariant` INV-3 が fail（idle 370,737 > TOL）。`_exitRealize` は adapter から
`mulDiv(mark, shares, supply)`(= raw mark の pro-rata) を idle へ pull するが、支払は
`requested = convertToAssets(shares)`（vault の `lockedProfit` 控除後 NAV・virtual-share 丸め込み）にクランプ。
**lockedProfit>0 や丸めで recall > payout となり、差分が idle に滞留**。価値喪失は無い（idle も totalAssets に計上）が、
非カストディ不変条件を破り、資金が再デプロイされず遊休化。**是正案**: payout 後の残 idle を `_deployToAdapter()`
で再投下、または recall を `payout` 見合いに縮小。

---

## F-4 (Low) — ERC-4626 revert selector の変更

新 `withdraw`/`redeem` は上限超過を文字列 `"ERC4626: withdraw/redeem more than max"` で revert。
OZ の `super.*` は custom error `ERC4626ExceededMaxWithdraw/Redeem(...)`。`test_lock_period_blocks_early_withdraw`
が selector 不一致で fail。integrator の error 解釈を壊しうる。**是正案**: OZ custom error を踏襲するか、テスト側訂正。

---

## §5 既存バッテリ 13 fail の内訳(I-3 前提)

| 分類 | テスト | 対応 |
|---|---|---|
| fork(RPC 未投入=B-3) | AaveV3Adapter{,Eth}ForkTest setUp | B-3 待ち。対象外 |
| **真の回帰** | test_H02_recall_fallsBack | **F-2** |
| **真の回帰** | SIXXVaultInvariant INV-3 | **F-3** |
| **真の回帰(selector)** | test_lock_period_blocks_early_withdraw | **F-4** |
| 旧 revert 仕様を符号化(設計変更で期待反転) | test_recall_reverts_on_adapter_shortfall / ExitFairnessE1 A,B,E / FundProtection bankRun,G1 / StressExitFreeze bricks / ThreatCouncil DoS_shortfall | 設計確定後に**期待値を新仕様へ再整合**（柱1 で revert が消えた=正しい方向。ただし F-1 の公平性は別途） |

---

## 完了定義に対する現状

- I-2: **新攻撃面を PoC で潰し済み → 未達**（F-1 は設計判断待ち・F-2/F-3/F-4 は是正案あり未適用）。
- I-3: **全 green → 未達**（13 fail）。
- ADR-007 検証項目（逆境で正当退出が必ず成功・価値公平）: **F-1 で価値公平が未達、F-2 で reverting-oracle 時に
  退出が stuck**。

> **凍結不可。** SHIN に F-1 の設計判断を諮り、方針確定後に F-2/F-3/F-4 の小差分是正 → 旧仕様テスト再整合 →
> I-3 全走 → B-3 fork → 再凍結の順で進める。
