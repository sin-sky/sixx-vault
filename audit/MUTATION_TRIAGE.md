# Mutation Testing Triage — SIXX Vault 会計コア

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
