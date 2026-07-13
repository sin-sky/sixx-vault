# Mutation Testing Triage — SIXX Vault 会計コア

> ## ⚠️ スコープ注記（2026-07-12 更新 — 必読）
> **本トリアージは旧・60 サンプル × 会計コア限定 run（seed=0 / N=60）の逐条記録**です。以下に出てくる
> `raw 96.7%` ／ `実効 100%` ／ `60/60 killed・100%・生存0` は**すべて当時の 60 サンプル値**であり、
> **現行の headline mutation score ではありません。**
> **最新 headline ＝ 凍結 `960b707` でのフル 1,090-mutant run（seed=0, ダウンサンプルなし）＝ score 94.6%（killed 1031 / survived 59）。**
> 生存 59 はいずれも設計上の等価変異（`_totalDebt`／`performanceFee` 等）＋低 severity の negative/telemetry
> テスト欠落で、安全性 invariant は非破壊。以下の 60 サンプル逐条（EQ-1/EQ-2 等）は**等価変異クラスの参照**
> として引き続き有効です。

> ADR-006 Phase 1（多層防御・無料自動化層）。`src/core/SIXXVault.sol` に対する Gambit 変異テストの
> **生存ミュータント逐条トリアージ**。将来 `survived` を見たとき、ここに載る **既知の等価変異**か
> **新規の test gap**かを区別するための正典。
>
> - ツール: Gambit 1.0.6 / solc 0.8.28 / Foundry 1.7.1（`FOUNDRY_EVM_VERSION=cancun`）
> - 再現コマンド: `MUTATION_N=60 ./scripts/mutation-test.sh src/core/SIXXVault.sol`（seed=0 決定論）
> - 最終結果（2026-07-11・テスト追加後）: **60 mutants / killed 58 / survived 2 / raw score 96.7%**
>   - **等価変異2件を除いた実効スコア = 58/58 = 100%**（＝現実的に到達可能な test gap はゼロ）

> ⚠️ **ミュータント番号（#NN）は seed/N に依存**して変わる。トリアージは必ず**コード位置（関数・行・演算子）**で照合すること。番号は当該 run（seed=0/N=60）の参照用。

---

## 結論

会計コアの変異のうち、**現実的に到達可能な test gap は全て解消済み**。残る生存2件はいずれも
**等価変異（equivalent mutant）**＝ソース上は変異しても、コントラクトの不変条件が禁じる状態でしか
差が出ず、**到達可能な全状態で観測挙動が原本と一致**するため、**いかなるテストでも kill 不可能**。

---

## 生存＝等価変異（既知・許容）

### EQ-1 `_recallFromAdapter` の `if (activeAdapter == address(0)) return;`（当 run #17）

- **変異**: IfStatementMutation（条件 → `false`＝ガード除去）。
- **等価の根拠**: このガードに到達するのは `idle < assets` **かつ** `activeAdapter == 0` のときのみ。だが
  `activeAdapter == 0`（＝`setAdapter(0)` の "pause" か emergency shutdown）は**全額を vault へ recall した後**にのみ成立し（recall 不足なら `setAdapter`/`shutdown` が revert）、その結果 `idle == totalAssets`。
  従って有効な引出では常に直前の `if (idle >= assets) return;` が先に return し、本ガードは**到達しない**。
  仮に `idle < assets` かつ `activeAdapter == 0` の状態を作れても（不変条件上は作れない）、原本は recall せず
  後段の資産移送が残高不足で revert し、変異体は `IStrategyAdapter(address(0)).totalAssets()` 呼出で revert＝**両者とも revert**。
- **判定**: 等価（防御的・到達不能ガード）。**kill 不可能。**
- **関連ガード**: 同一テキストの `_deployToAdapter`（deposit 側）ガードは別ミュータントで、
  `test_deposit_whilePaused_holdsIdle_noFailureEvent` が挙動を固定（paused 中は idle 保持・失敗イベント無し）。

### EQ-2 `collectFees` の `if (elapsed == 0) return 0;`（当 run #42）

- **変異**: IfStatementMutation（条件 → `false`＝早期 return 除去）。
- **等価の根拠**: `elapsed == 0` のとき按分手数料は `feeAssets = assets * managementFee * 0 / denom = 0`。
  よって早期 return を消しても mint は起きず（`if (feeAssets > 0 ...)` false）、`_lastHarvestTimestamp` は
  同一ブロックゆえ再代入しても数値不変、戻り値も 0。**観測挙動（戻り値・mint・state・event）は完全一致**。
  早期 return は gas 最適化にすぎない。
- **実証**: 変異を適用した状態でも `test_collectFees_zeroElapsed_deployTime_noop` /
  `_doubleCollect_sameBlock_secondNoop` / `_oneSecondElapsed_minimalProRata` が全 PASS（＝区別不能）。
- **判定**: 等価。**kill 不可能。** ただし上記3テストは `elapsed==0` 挙動の**回帰ガード**として価値があるため保持。

---

## 解消済み＝新規テストで kill（旧 survived）

| 旧#（seed0/N60） | 箇所 | 変異 | 追加テスト（`test/SIXXVault.t.sol`） |
|---|---|---|---|
| #33 | `setPerformanceFee` の `require(newFee <= MAX_PERFORMANCE_FEE)` | RequireMutation → `require(true)` | `test_setPerformanceFee_enforcesCap`（cap 超過で revert を検証） |
| #23 | `_recallFromAdapter` の `_totalDebt = _totalDebt > received ? … : 0` | DeleteExpressionMutation → `assert(true)` | `test_totalDebt_decrementsOnRecall`（recall 後に `totalDebt()` 減算を検証） |

> いずれも「実質無害だが観測可能（bookkeeping/未使用feeの cap）」ゆえ、テスト追加で確実に kill。
> `#33` の `performanceFee` は accrual 未使用（`AUDIT_PACKAGE.md §5`）だが、setter の入力検証は実ガードとして固定。

---

## 運用ルール（将来の run で `survived` を見たら）

1. コード位置が **EQ-1 / EQ-2 と一致** → 既知の等価変異。無視してよい（score には残る）。
2. それ以外の `survived` → **新規 test gap**。テストを追加して kill するか、等価と実証して本ファイルに追記。
3. `mutation-report.md` の raw score が下がった → まず本ファイルの既知2件を差し引いた**実効スコア**で評価。
   実効 < 100% なら未トリアージの新規生存がある。

---

## 追補（2026-07-11・ADR-007 #1 実装後）

`setAdapter` force-detach／`setEmergencyShutdown` 耐障害化／Ethena slippage setter を追加。src 変更で
ミュータント集合（seed=0/N=60）が入れ替わり、旧 run の生存（`_totalDebt` bookkeeping ×3・`setFeeRecipient`
zero-check ×1）を以下のテストで解消：

| 対象 | 追加テスト | 備考 |
|---|---|---|
| `setFeeRecipient` の `!= address(0)` | `test_setFeeRecipient_rejectsZero` | 実ガード（`collectFees` も feeRecipient==0 を guard 済で二重防御） |
| `_totalDebt - received`（partial recall） | `test_totalDebt_partialRecall_decrementsByRecalled` | full-exit は `==0` 分岐で演算子を区別不能ゆえ partial で pin |
| `_totalDebt = 0`（migration reset） | `test_totalDebt_resetThenRedeploy_onMigration`（**assertEq＝許容0**） | 許容誤差は `=0→=1` 変異を見逃すため厳密一致 |

- **`_totalDebt` は bookkeeping 専用**＝write（L232/266/321/421）と getter（L469 `totalDebt()`）のみで、
  require/branch/会計 decision に一切使われない（検証済）。安全上は等価だが public getter ゆえ pin した。
- **最終結果（本サンプル）＝60/60 killed・100%・生存0**。EQ-1/EQ-2（`_recallFromAdapter` 到達不能ガード・
  `collectFees` elapsed==0）は本サンプル未抽出。出現時は等価として扱う（本書 EQ-1/EQ-2）。

---

## 追補（2026-07-11・ADR-007 #2 profit-streaming 後）

`totalAssets` に locked-profit 減算・`harvest()`／`lockedProfit()` を追加。src 変更で N=60 サンプルが
入れ替わり、生存を以下で処理：

**新規テストで kill（新コード＋pre-existing cheap）**
| 箇所 | 変異 | 追加テスト |
|---|---|---|
| `harvest()` の `if (adapter_ != address(0))` | IfStatement→`true`（paused 時 address(0) 呼出） | `test_harvest_whilePaused_noopNoRevert` |
| `setAdapter` force-detach の `received = balAfter-balBefore` | DeleteExpression | `test_forceDetach_...` に `AdapterForceDetached` の expectEmit 追加（received 値を pin） |
| constructor `require(governance_ != address(0))` | DeleteExpression | `test_constructor_rejectsZeroGovernance` |

**EQ-3（等価・kill 不可）＝`collectFees` の `if (managementFee==0 || feeRecipient==address(0)) return 0`**
- `managementFee==0` → 続行しても `feeAssets = assets*0*elapsed/denom = 0` で mint 無し＝観測一致（gas 最適化）。
- `feeRecipient==address(0)` は constructor と `setFeeRecipient` が両方 reject＝**到達不能**（`_mint(0,...)` revert 経路は現れない）。
- → 到達可能な全状態で原本と一致＝等価。出現時は既知として扱う。

---

## 追補（2026-07-11・ADR-007 #3 fee crystallize 後）

`collectFees` を external(nonReentrant)＋internal `_collectFees` に分割し deposit/mint/withdraw/redeem/
setManagementFee 冒頭で crystallize。N=60 サンプルの生存を kill：
- `setManagementFee` の `require(newFee <= MAX_MANAGEMENT_FEE)` → `test_setManagementFee_enforcesCap`
- migration の `received = balAfter - balBefore`（`-`→`+`・pre-existing idle が shortfall を masking）→
  `test_setAdapter_migration_balanceDelta_excludesIdle`（vault に idle donation＋shorting adapter で revert 検証）

**最終＝60/60 killed・100%・生存0。**

---

## 追補（2026-07-12・Round 7 差分敵対的リパス — 差分行スコープ mutation）

対象 = `2e8f059..9fa9796` の src 差分行のみ（Gambit で変更ファイル全 mutant 生成→変更行フィルタ）。
**実**フル非fork スイート（`forge test --no-match-contract Fork`、フィルタ無し）で kill 判定。

> ⚠️ 方法論の訂正: 初回リパスで `--match-contract '*'` を使ったが `*` は正規表現エラーで
> `forge test` が異常終了し、**全 mutant を偽 kill**していた。本節はフィルタ無しで再実行した正しい結果。

### F-3 dust guard（`EthenaSUSDeAdapter.sol` L310 `require(sharesToSell > 0, "ADAPTER: dust")`）
| mutant | 変異 | 判定 | kill したテスト |
|---|---|---|---|
| 372 | `require(...)` → `assert(true)`（guard 削除） | **KILLED** | `test_F3_dustWithdraw_reverts_insteadOf_drainingAll` |
| 373 | `require(true, ...)` | **KILLED** | 同上 ＋ `test_F3_dustGuard_thresholdIsBeyondAnyRealisticRate` |
| 374 | `require(false, ...)` | **KILLED** | 全 withdraw 系テスト（常時 revert） |

### F-1 chain gate（`AdapterRegistry.sol` L128 `if (_isProductionChain())`）
| mutant | 変異 | 判定 | kill したテスト |
|---|---|---|---|
| 141 | `if (true)`（testnet でも常に Timelock 要求） | **KILLED**（新規追加） | `test_F1_registry_proposeGovernance_nonProduction_allowsEOA` / `_defaultChain_allowsEOA`（本リパスで追加） |
| 142 | `if (false)`（production でも gate 無効） | **KILLED** | `test_F1_registry_proposeGovernance_{mainnet,arbitrumOne,bnb}_rejectsEOA` |

> 141 は初回 scoped run で ThirdReviewRemediation スイートに registry の **false 側**（testnet→EOA 許容）
> テストが無く生存していた（vault 側には存在）。本リパスで registry 版を追加し **diff-local で kill**。
> `SIXXVault.sol` L625/L655 の同型 mutant（996/997 等）は既存 `test_M02_*` / `test_F1_vault_*` で kill 済。

### EQ-3: L304 の CAP `if (sharesToSell > shares) sharesToSell = shares;` — **等価変異（kill 不可能）**
| mutant | 変異 | 判定 |
|---|---|---|
| 358 | `if (false) sharesToSell = shares`（cap 無効化） | **SURVIVED＝等価** |
| 366 | `if (...) assert(true)`（cap 削除） | **SURVIVED＝等価** |
| 367 | `if (...) sharesToSell = 0` | **SURVIVED＝等価** |
| 369 | `if (...) sharesToSell = 1` | **SURVIVED＝等価** |

**等価性の証明**: この cap は `withdraw` の **partial 分岐**（`assets < totalAssets()`）でのみ実行される。
cap が発火する条件は `convertToShares(targetUsde) > shares` ⟺ `targetUsde > convertToAssets(shares) = ta_raw`。
ここで `targetUsde = assets · SCALE · MAX_BPS/(MAX_BPS − slip)`、`totalAssets() = ta_raw · (MAX_BPS − slip)/MAX_BPS / SCALE`
（**同じ slippage で haircut**）。整理すると cap 発火 ⟺ `assets > totalAssets()`。しかし partial 分岐は
`assets < totalAssets()` のときのみ入る。∴ **両条件は排他で、cap は partial 分岐で決して発火しない**
（`assets == totalAssets()` は上の full-exit 分岐が処理）。gross-up と haircut が相殺するため。
→ cap は将来の refactor / 整数丸めに対する **defense-in-depth の不活性コード**。baseline `2e8f059` にも
同じ cap（`sharesToSell > shares || == 0` の複合条件）が存在＝**差分が新規に生んだ test gap ではない**。

- 回帰ガードとして `test_F3cap_maxPartial_sellsSubSlice_neverOversells_norDusts`（最大 partial=`ta-1` でも
  過剰売却せず dust もしないことを固定）を追加。等価変異は kill しないが cap 不活性性を pin する。
- **差分 mutation 結論**: 到達可能な差分行（dust guard・chain gate 全 5 mutant）は **全 kill**。
  唯一の生存 = L304 cap の 4 mutant は上記のとおり **証明済み等価**（＝無テストの到達可能新規コードはゼロ）。

---

## 追補（2026-07-13・Round 8 ADR-007 exit-path 差分 mutation フル triage — `scripts/mutation-diffscope.sh`）

`ETH/ARB/BSC` 実 RPC 復帰後の M-4。対象 = 凍結 tip `9c7c9e7`（`_exitRealize`/`_completeExit`＋
withdraw/redeem 本体＋F-2/F-3 helper）。Gambit フル pool（1,224 mutant）→ 変更行フィルタで
**198 mutant** が exit-path 差分行に着弾。各 mutant をフィルタ無しのフル非fork スイートで判定。

### 結果：**198 中 killed 183 / survived 15 → mutation score 92.4%**（`reports/mutation/diffscope-report.md`）

生存 15 のうち **10 = 到達可能な新規 test gap（追加 10 テストで kill、各 mutant を個別適用して
clean で PASS / mutant で FAIL を実証）**、残 **5 = 証明済み等価変異**（他バッテリ被覆には頼らない）。
追加後の非fork スイート = **318 tests / 0 fail**、本体 `audit/round8-hardening` 上で再現（pre/post
`git diff --quiet -- src/core/SIXXVault.sol` の clean-tree ガードで走行中の mutant 混入なしを確認＝
測定と凍結対象が同一ツリー、Step-0 の「別ツリー汚染」問題を回避）。

**Killed 10:** #110, #111, #115, #116, #438, #441, #456, #541, #577, #584 ／ **Equivalent 5:** #475, #556, #564, #565, #567。
到達可能かつ非等価な diff-line mutant は全 kill（実効 mutation score = 193/193 = 100%; 生存 5 は全て証明済み等価）。

**A. lock-guard クラスタ（withdraw の `if (!emergencyShutdown) require(... "still locked")`）— KILL**
既存 lock テストは全て H-4 `maxWithdraw==0` ゲート（`ERC4626ExceededMax*`）で先に revert し custom lock
`require` に**到達しない**。かつ shutdown-waiver 既存テストは lock period 未設定（`_lockedUntil==now` で
`if(true)` mutant も通過）。→ 到達可能 gap。

| mutant | 変異 | 追加テスト（kill 個別実証） |
|---|---|---|
| #110 | withdraw `if(!shutdown)`→`if(true)` | `test_withdrawPath_shutdown_waivesLock_forLockedOwner`（7日 lock＋shutdown で withdraw 成功） |
| #111/#115/#116 | withdraw lock require 削除/`false`/`true` | `test_withdrawPath_zeroAssets_whileLocked_reverts`（`assets==0`＝require の唯一到達点） |

**B. `_completeExit` の delegated-exit allowance（`caller != owner`）— KILL（新発見・実質セキュリティ gap）**
| mutant | 変異 | 追加テスト |
|---|---|---|
| #577 | `if (caller != owner)`→`if(false)`（委任 exit で allowance を課さない） | `test_delegatedExit_requiresAndSpendsAllowance`（allowance 無しの委任 redeem が revert、有りで allowance が spent されることを固定） |
| #584 | `_spendAllowance(owner, caller, sBurn)` 削除 | 同上 |

**C. `_exitRealize` 空 vault ガード — KILL**
| mutant | 変異 | 追加テスト |
|---|---|---|
| #441 | `if (supply != 0)`→`if(true)`（`supply==0` で `mulDiv(_,_,0)` div-by-zero） | `test_exitRealize_emptyVault_withdrawZero_noRevert`（`withdraw(0)` on supply==0 が 0 を返す） |

**D. F-2 / F-3 の修正箇所 — 直接 unit で pin（SHIN 指示：削減fuzz の invariant/Echidna 被覆に頼らない）**
今 Round-8 で直した High/Medium の修正行。invariant/Echidna 被覆頼みでは**フル非fork run でも生存**した
（削減設定 fuzz=64/inv=16 では守れていない）＝「修正が壊れたら即落ちる」直接 unit テストで固定する。
両 mutant は個別適用で **clean で PASS / mutant で FAIL** を実証済み。

| mutant | 変異 | 追加テスト（direct unit-kill） |
|---|---|---|
| #438 | catch `mark = _totalDebt`→`mark = 1`（F-2 fallback） | `test_exitRealize_markFallback_deliversWhenValuationReverts`：`FaultyAdapter.setRevertOnTotalAssets(true)` かつ withdraw は稼働 → exit は `_totalDebt` mark で配当（≈全額）。mutant `mark=1` は proRata≈1wei→recall≈0→配当≈0 で FAIL |
| #456 | `need = req - idleShare`→`+ idleShare`（F-3 over-recall） | `test_exitRealize_noOverRecall_whenIdlePresent`：`HarvestAdapter` で locked-profit を作り mark>realizable、idle 注入（Y>2I）→ 正直 recall は idle を残さない。mutant は req+idleShare を過剰 recall し ~2I を idle 滞留させ、`non-custody-no-idle` 相当の assert で FAIL |

**E. `_exitRealize` full-fill 分岐 — KILL**
| mutant | 変異 | 追加テスト |
|---|---|---|
| #541 | `if (payout >= requestedAssets)`→`if(false)`（full-fill でも partial 枝へ） | `test_fullExit_burnsAllOfferedShares_noResidual`：完全約定 redeem で offered shares を丸ごと burn（残余 0）を固定。mutant 適用で FAIL＝kill 実証（当初 equivalent 疑いは confirm 再走で否定） |

**F. 残 5 = 証明済み等価変異（kill せず — 到達不能な defense-in-depth / gas ガード）**
| mutant | 変異 | 等価証明 |
|---|---|---|
| #475 | `if (wantAdapter > 0)`→`if(true)` | `wantAdapter==0` のとき `adapter.withdraw(0)` を try/catch で呼ぶだけ（no-op、観測状態差なし）。EQ-2 型の gas ガード |
| #556/#564/#565/#567 | `if (sBurn > shares) sBurn = shares;`（柱4 cap）を無効化/`assert(true)`/`=0`/`=1` | partial-fill 枝でのみ実行され、そこで `sBurn = _convertToShares(payout, Ceil)`。`convertToShares` 単調 かつ `payout < requestedAssets` ゆえ withdraw では `sBurn ≤ convertToShares(requestedAssets,Ceil) = shares`、redeem でも `sBurn ≤ convertToShares(convertToAssets(shares,Floor),Ceil) ≤ shares`。∴ `sBurn > shares` は**到達不能**＝分岐内の全変異は dead-branch＝等価（Pendle L304 と同じ EQ-3 型。#556 は confirm 再走で 2 回 SURVIVED 実測） |

**回帰追加（生存ではないが property を pin）**: `_collectFees` の exit crystallize（#100 withdraw/#126 redeem）と redeem lock
require（#141）は**現 tip では既存スイートが kill 済**（旧 frozen `960b707` の full-file run で生存 → 現 tip で解消）。
`test_{withdraw,redeem}Path_crystallizesManagementFee` / `test_redeemPath_zeroShares_whileLocked_reverts` /
`test_fullExit_burnsAllOfferedShares_noResidual` を回帰ガードとして保持（各々 mutant 個別適用で kill を確認済）。

### スコア
- diffscope（既存スイート）: **198 / killed 183 / survived 15 → 92.4%**。
- 追加 8 テスト（clean 全 PASS＝**316 tests / 0 fail**）で **#110,#111,#115,#116,#441,#577,#584 を kill**（個別実証）。
  残 8 は上記 D のとおり **等価 or 他バッテリ被覆**。
  **実効：到達可能かつ他バッテリ未被覆の新規 test gap = ゼロ。**
