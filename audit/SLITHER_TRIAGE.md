> ℹ️ 正典は workspace `threads/sixx-vault/SLITHER_TRIAGE.md`（`sin-sky/sixx-workspace`）。
> 本ファイルは監査ハンドオフ自己完結のための同梱コピー（`3917de7` 時点）。

# Slither 静的解析 トリアージ — sixx-vault

> 区分: 🟢 done（解析+全件トリアージ）。2026-06-29。対象 `sixx-vault` src（`lib/` 除外）。
> ツール: Slither 0.11.5 / solc 0.8.28。コマンド: `slither . --filter-paths "lib/"`。
> 結果: 28 contracts / 101 detectors / **46 results**。**High 0・実 Medium 0**。

---

## 結論

**実セキュリティ問題ゼロ。** 全 46 件は ①意図的設計 ②偽陽性 ③将来デプロイ用の最適化 のいずれか。
High 系検出器（arbitrary-send / suicidal / controlled-delegatecall / reentrancy-eth / unprotected-upgrade / weak-prng）は **0 件**。
**今回の Venus dust trap 修正が新規の実問題を入れていないことも確認**（下記 reentrancy-balance は偽陽性）。

## 検出器別トリアージ

| 検出器 | 箇所 | 判定 | 理由 |
|---|---|---|---|
| reentrancy-no-eth | `setAdapter` | 受容 | 外部呼は **registry でホワイトリストされた adapter** のみ。`onlyGovernance`(Safe)。状態更新は呼出後で整合。信頼モデルで緩和。 |
| reentrancy-benign/events | `_deployToAdapter`/`_recallFromAdapter`/`setAdapter`/`setEmergencyShutdown` | 受容 | 同上＝信頼 adapter への呼出。benign/event 系＝低重大度。 |
| reentrancy-balance | **`VenusUSDTAdapter.withdraw`(今回の修正)** | **偽陽性** | `vBal=balanceOf` を読んで即 `redeem(vBal)`。`onlyVault`＋呼出先は信頼 Venus vToken。`withdrawn` は呼出**後**の実残高デルタで算定＝stale 不使用。reviewer も re-entrancy 面なしと確認済。 |
| incorrect-equality | `withdraw`/`getActiveAdapters`/`isActive`/`_deployToAdapter`/`_recallFromAdapter`/`collectFees` | 受容 | すべて制御フロー guard（`idle>=assets`/`toWithdraw==0`/`supply==0` 等）。残高の値操作で破れる等価ではない。 |
| unused-return | vault→adapter `deposit`/`withdraw` 4箇所 | 意図的 | vault は戻り値を使わず**独立に残高を再 read**。`_totalDebt` は bookkeeping aid（balance でない＝CLAUDE.md 明記）。custody/reviewer 確認済。 |
| divide-before-multiply | `collectFees` の M-1 希釈式 | 意図的 | `feeShares=feeAssets*supply/(assets-feeAssets)`＝CLAUDE.md M-1 の確定式。precision loss は sub-share dust。 |
| timestamp | `collectFees` | 意図的 | 時間按分の管理報酬＝`block.timestamp` 利用は本質的。操作余地は採掘者の数秒で fee 計算に実害なし。 |
| missing-zero-check | constructor `adapterRegistry_` | 意図的 | **`address(0)` は有効な「registry 無し」モード**（H-1 で check を bypass）＝ゼロ拒否してはいけない。 |
| uninitialized-local | `getActiveAdapters` の `count`/`idx` | 偽陽性 | Solidity で uint は 0 既定＝ループカウンタとして正。 |
| naming-convention | `__atomicPushToAdapter` | 様式 | external だが内部用途の意図的命名。 |
| events-maths | （setter 系） | 情報 | 数値変更にイベント無し＝可観測性の提案。 |
| cache-array-length | `AdapterRegistry.getActiveAdapters` ループ | 最適化 | `_adapterList.length` をキャッシュ＝gas 削減。 |
| immutable-states | `SIXXVault.adapterRegistry` | 最適化 | constructor のみ代入（line 76）＝`immutable` 化で gas 削減。 |

## 将来デプロイ時の任意改善（コード未変更＝デプロイ済み契約を今は触らない）

次回 Vault/adapter 再デプロイ（例＝Venus dust trap 修正の adapter 再デプロイ）の機に、以下を**任意で**取り込み可：
1. `SIXXVault.adapterRegistry` を `immutable` 化（gas・意図明確化）。
2. `AdapterRegistry.getActiveAdapters` のループで `_adapterList.length` をキャッシュ。

> いずれも**機能・セキュリティに影響しない最適化**。今回は所見出しが目的のためコード変更なし。外部監査（SHIN 発注）の入力として本トリアージを渡せる。

---

## 追補（2026-07-11・ADR-007 #1 実装後）

`setAdapter` の force-detach（try/catch）／`setEmergencyShutdown` の totalAssets 耐障害化を追加。
slither の "新規" 16件は**行番号シフトによる id ずれ＋同一 FP クラスの新インスタンス**で、危険検出器（arbitrary-send / suicidal / delegatecall / reentrancy-eth / unprotected-upgrade / weak-prng）は **0件**。逐条は既存トリアージと同型：

| 新規箇所 | 検出器 | 判定 | 理由 |
|---|---|---|---|
| `setAdapter` force-detach の `withdraw(marked)` 戻り値 | unused-return | 意図的 | balance-delta（`received=balAfter-balBefore`）で算定＝戻り値非依存（M13-16 同型） |
| `setAdapter.marked` / `.received` | uninitialized-local | 偽陽性 | Solidity zero-init が正（marked は try/catch 両分岐で代入・received は marked==0 時 0 が正） |
| `setAdapter` / `setEmergencyShutdown` の try/catch 外部呼 | reentrancy-no-eth / -balance / -benign / -events | 受容 | 全経路 `nonReentrant` 配下＋呼出先は registry whitelist 済 adapter（信頼モデル）。状態更新順は整合 |
| `collectFees` の incorrect-equality / divide-before-multiply | — | 意図的 | M-1 希釈式・制御 guard（既存トリアージと同一） |
| Ethena `totalAssets` incorrect-equality / exchange 系 unused-return | — | 意図的 | `shares==0` guard・Curve `exchange` は min_out で保護し実残高で検算 |

→ baseline（`audit/slither-baseline.json`）を再凍結（70件）。実問題ゼロ。正典 workspace `threads/sixx-vault/SLITHER_TRIAGE.md` も同期予定。

## 追補（2026-07-11・ADR-007 #2 profit-streaming 後）

`totalAssets` に locked-profit 減算・`harvest()`（profit 実現→lock）・`lockedProfit()` を追加。
slither "新規"15件は**行シフトの id ずれ＋同型 FP**（危険検出器 0）。新規箇所：`harvest()` の
`adapter.harvest()` 戻り値 unused-return＝**balance-delta で profit を算定**（before/after の totalAssets 差）
＝M13-16 同型で戻り値非依存＝意図的。baseline 再凍結。

## 追補（2026-07-11・ADR-007 #3 fee crystallize 後）
`collectFees` を external(nonReentrant) ラッパー＋internal `_collectFees` に分割し deposit/mint/withdraw/redeem/setManagementFee 冒頭で呼出。slither "新規"は行シフトの id ずれ＋同型 FP（危険 0）。baseline 再凍結。

## 追補（2026-07-11・独立 Handoff 監査 M-01〜M-05/L-01 remediation 後）
外部レビュー（`SIXX_Vault_Handoff_Audit_Report.md`）の M-01（fee 0→非0 anchor 前進）・M-02（zero-profit harvest でクロック非更新）・M-03（force-detach writeoff で lockedProfit クリア＋deposit 一時停止）・M-04（Pendle deposit で USDe/PT の balanceOf デルタ検算）・M-05（部分引出の2レグ複利 gross-up）・L-01（Pendle deploy を broadcast/resume で hard-revert）を反映。

`(検出器, 関数)` 単位で baseline と差分を取ると、行シフトによる id ずれを除いた**真の新規は以下 2 点のみ**。いずれも **M-04 の残高デルタ・ハードニングそのものの副作用**で、既存トリアージと同型の受容/意図クラス。危険検出器（arbitrary-send / suicidal / delegatecall / reentrancy-eth / unprotected-upgrade / weak-prng）は **0 件**。

| 新規箇所 | 検出器 | 判定 | 理由 |
|---|---|---|---|
| `PendlePTAdapter.deposit` の `usdeBefore/usdeIn`・`ptBefore/ptGained`（M-04 残高デルタ read×4） | reentrancy-balance | 偽陽性 | `deposit` は `nonReentrant`＝再入不可。残高 read は M13-16 と同型の balance-delta 検算（`_recallFromAdapter`/`setAdapter` で既受容の FP クラス）。stale 値は不使用。 |
| `PendlePTAdapter.deposit` の `swapper.swap(...)` 戻り値（1→2件目） | unused-return | 意図的 | M-04 の要諦＝swapper の戻り値を**信用せず**実 USDe 残高デルタで検算し `require(usdeIn>=usdeMin)`。戻り値を捨てるのが仕様。 |

その他の "新規" は `_recallFromAdapter`/`setAdapter`/`setEmergencyShutdown`/`__atomicPushToAdapter`/`VenusUSDTAdapter.withdraw`/`_collectFees` 等**今回未編集関数**の行シフト id ずれ＝既存トリアージと同一。M-05 の `buffered = target*BPS*BPS/(slipDenom*slipDenom)` は multiply-before-divide（新規 divide-before-multiply なし）。→ baseline（`audit/slither-baseline.json`）を再凍結。実問題ゼロ。

## 追補（2026-07-12・第2独立レビュー H-01/M-01 remediation 後）

第2独立レビューの **H-01**（force-detach で totalAssets() revert 時も deposit 停止：`setAdapter` に
`navReadOk` 追跡＋`depositsPaused=true`＋`AdapterNavUnreadableOnDetach`／`maxDeposit`・`maxMint`
に pause 反映）・**M-01**（Pendle `_swapVia` で swap 毎 exact-approve→0＝swapper 無期限 allowance 廃止）を反映。

`(検出器, 関数)` 単位で baseline 差分を取ると、危険検出器（arbitrary-send / suicidal /
controlled-delegatecall / reentrancy-eth / unprotected-upgrade / weak-prng / tx-origin）は
**0 件**。"新規" 28 件はすべて**行シフト id ずれ＋既存 FP クラスの同型インスタンス**で、真に新しいのは
以下 1 点のみ：

| 新規箇所 | 検出器 | 判定 | 理由 |
|---|---|---|---|
| `SIXXVault.setAdapter.navReadOk` | uninitialized-local | 偽陽性 | 既存 `marked`/`received` と同一クラス。Solidity zero-init が正＝`navReadOk` は既定 `false`（＝read 未成功）、`try` 成功分岐でのみ `true`。両分岐で意味が確定。 |

その他は既存トリアージと同型：`setAdapter`/`_recallFromAdapter`/`deposit`/`withdraw` の
reentrancy-balance・reentrancy-no-eth（全経路 `nonReentrant`＋registry whitelist 済 adapter＝信頼モデル、
状態更新は CEI 整合、`received` は balance-delta）／`_collectFees` の M-1 希釈式 divide-before-multiply・
incorrect-equality（`supply==0` 等の制御 guard）／vault→adapter `withdraw`/`deposit` の unused-return
（実残高デルタで算定＝M13-16）。M-01 の `_swapVia`（`forceApprove(swapper,amountIn)`→`swap`→`forceApprove(swapper,0)`）は
`deposit`/`withdraw`（`nonReentrant`）配下＝新規 reentrancy-eth 等を生まない。

→ baseline（`audit/slither-baseline.json`）を `--update-slither-baseline` で再凍結。実問題ゼロ。

## 追補（2026-07-12・第3レビュー H-02/M-02/M-03/L-02/L-03 remediation 後）

第3レビュー remediation を反映：
- **H-02**：`totalAssets()` を try/catch 化（adapter read 失敗時 `_totalDebt` fallback＝revert しない）／
  `_recallFromAdapter` の `available` 読取を try/catch＋best-effort `needed` fallback。
- **M-02**：`SIXXVault`/`AdapterRegistry` の `proposeGovernance` に mainnet（chainid==1）Timelock 強制
  （`code.length>0`＋`ITimelockMinDelay.getMinDelay()>=48h`、try/catch）。
- **M-03**：`setAdapter` に `asset()==asset()`・`vault()==this`・`governance()==governance`（best-effort）検証。
- **L-02**：Aave/Venus/Ethena の `rescueToken` に `token != asset` 追加。
- **L-03**：`AdapterRegistry` に `MAX_ADAPTERS=100` cap（`registerAdapter`）。

`(検出器, 関数)` 差分の "新規" 20 件はすべて**行シフト id ずれ＋既存 FP クラスの同型インスタンス**。
危険検出器（arbitrary-send / suicidal / controlled-delegatecall / **reentrancy-eth** / unprotected-upgrade /
weak-prng / tx-origin）は **0 件**。逐条：

| 新規箇所 | 検出器 | 判定 | 理由 |
|---|---|---|---|
| `totalAssets`／`_recallFromAdapter` の adapter try/catch 読取 | reentrancy-balance / uninitialized-local | 偽陽性 | H-02 の revert 耐性化。`totalAssets` は `view`、`_recallFromAdapter` は `withdraw`（`nonReentrant`）配下。try 変数の zero-init は正（既存 `navReadOk`/`marked` と同型）。 |
| `setAdapter` の binding 検証（`asset()`/`vault()`/`governance()` 外部呼） | reentrancy-no-eth / unused-return / incorrect-equality | 意図的/受容 | M-03。`onlyGovernance`＋`nonReentrant` 配下・view staticcall。`==` は binding 一致判定（値操作で破れる等価でない）。 |
| `proposeGovernance` の `getMinDelay()` 外部呼（vault/registry） | reentrancy-no-eth / unused-return | 受容 | M-02。`onlyGovernance`・mainnet のみ・view staticcall。戻り値は `require(d>=48h)` で使用（unused ではない箇所も id ずれ）。 |
| `_collectFees`／Pendle 系の incorrect-equality・divide-before-multiply・unused-return | — | 意図的 | 既存トリアージと同一（M-1 希釈式・制御 guard・balance-delta）。行シフト id ずれ。 |

→ baseline を `--update-slither-baseline` で再凍結。実問題ゼロ。

---

## Round 7（`9fa9796`／内部 adversarial hardening F-1・F-3）

自発 adversarial パスの修正（`audit/ADVERSARIAL_HARDENING_2026-07-12.md`）：
- **F-1**：`SIXXVault`/`AdapterRegistry` の `proposeGovernance` の mainnet Timelock 強制を
  `chainid==1` → `_isProductionChain()`（`{1, 42161, 56}`）に拡張。
- **F-3**：`EthenaSUSDeAdapter.withdraw` の部分 exit ダストを全清算せず `require(sharesToSell>0, "dust")` で revert。
- コメント精度（Venus staleness／Ethena depeg scope）。

slither 差分の "新規" **7 件**はすべて**行シフト id ずれ＋既存 FP クラスの同型インスタンス**（F-3 と
コメント編集で Venus/Ethena の行番号が動き、slither の content-hash `id` が変化しただけ）。危険検出器
（arbitrary-send / suicidal / controlled-delegatecall / reentrancy-eth / unprotected-upgrade / weak-prng /
tx-origin）は **0 件**。逐条：

| 新規箇所 | 検出器 | 判定 | 理由 |
|---|---|---|---|
| `VenusUSDTAdapter.withdraw` | reentrancy-balance | 偽陽性 | 既存トリアージ済（本表冒頭）。`onlyVault`＋`nonReentrant`、`withdrawn` は呼出後の実残高デルタ。コード不変・staleness コメント追記で行シフトのみ。 |
| `VenusUSDTAdapter.withdraw` | incorrect-equality | 受容 | `redeem/mint/redeemUnderlying == 0` の error-code guard。コード不変。 |
| `EthenaSUSDeAdapter.totalAssets` | incorrect-equality | 意図的 | `shares == 0` guard。コメント編集で行シフトのみ。 |
| `EthenaSUSDeAdapter.deposit`／`withdraw` の Curve `exchange()`・`susde.deposit()`（4 件） | unused-return | 意図的 | M-04。戻り値を信用せず実残高デルタで検算・`min_out` で保護。F-3 修正で行シフトのみ（`exchange` 呼自体は不変）。 |

→ baseline を再凍結（`audit/slither-baseline.json` 更新）。実問題ゼロ。

---

## Round 8 v2（`06e13c9`／裁定 F: idle-only burn-price skim ガード）

`_exitRealize` の F guard 追記（`bool valuationReadable` ＋ `if (!valuationReadable && !emergencyShutdown) return (0,0)`,
src +32 行）で `_exitRealize`（#339-424）以下の行番号が動き、slither の content-hash `id` が変化。**baseline は
`0245fd9`（b835c09 より前）で凍結され stale** だったため、差分は **15 件**を「新規」と表示。うち **14 件は
既トリアージ済クラスの行シフト再配置**（(detector, function) が baseline に一致）、**1 件のみ真に baseline 未収録**:

| 新規箇所 | 検出器 | 判定 | 理由 |
|---|---|---|---|
| `SIXXVault._adapterValuationReadable`（**b835c09 由来**、本 commit ではない） | unused-return | 意図的・良性 | C-1 guard の valuation プローブ `try totalAssets() returns (uint256) {} catch {}`。戻り値は**意図的に破棄**（読めるか否かのみを判定）。既トリアージの unused-return クラス（`setAdapter`/`harvest`/`_deployToAdapter` の withdraw/deposit/harvest 戻り値破棄）と同型。危険性なし。 |

危険検出器（arbitrary-send / suicidal / controlled-delegatecall / reentrancy-eth / unprotected-upgrade /
weak-prng / tx-origin）は **0 件**。**本 commit（06e13c9 vs b835c09）が追加した新 finding クラスはゼロ**
（F guard は external call/storage/equality を一切追加しない）。15 件はすべて行シフト＋b835c09 の良性 probe。

→ baseline を再凍結（`audit/slither-baseline.json` ← clean-tree ガード下で生成した `reports/slither-current.json`）。実問題ゼロ。
