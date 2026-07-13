# Round 8 — 内部敵対的リパス（2026-07-13）

> 基準: `main` tip（`9fa9796` のソース本体＝Round 7 凍結と同一）。solc 0.8.28。
> 手法: コア/Vault・Ethena・Pendle・Aave+Venus+wiring の 4 領域を独立に敵対的レビューし、
> 既知findings（H-1〜4 / M-1〜5 / F-1〜3 / L-*）の**外側**にある新規issueのみを抽出。

## 総括（B-1/B-2 反映後）

- **新規 High/Critical はゼロ。** 既知findingsはすべて再プローブに耐えた。
- 実修正 = **3件**：
  - **R8-2**（Pendle exit を balance-delta 化）— 維持。
  - **Gap#3**（Venus partial withdraw を実残高デルタ化）— B-2(i) の兄弟掃討で発見。
  - **A6**（emergency shutdown で管理手数料窓を waive）— B-2(ii) の状態リセット掃討で発見。※手数料ポリシー変更・veto 可。
- **撤回 = 1件**：**R8-1**。当初「shutdown が `_lockedProfit` を残す」を finding としたが、B-1 PoC で「クリアする方が JIT を再導入（抽出 ≈500〜990）」と判明→**誤診として revert**。shutdown はソース変更なし＋根拠コメント。
- **許容（コメント/根拠明記）**：Aave Gap#2・shutdown recall Gap#1・評価 mark Gap#4、および状態リセット非対称の大半。
- Ethena と wiring は clean（指摘は doc nit のみ）。
- **未収束**：B-3（fork 実行・Step 0）残。main マージ・再凍結・束再生成は未実施。

## R8-1 — 誤診として撤回（当初「shutdown が `_lockedProfit` を残す」／NON-FINDING）

> **経緯**: 初回コミット `dfdb35e` で「force-detach は `_lockedProfit=0` するのに shutdown は残す＝非対称」を
> Low finding とし、shutdown 起動時にクリアする修正を入れた。B-1 PoC でこの修正が **有害**と判明し **revert**。

- **当初の主張**: shutdown 中も `_lockedProfit` が残ると `totalAssets()` が最大8h過小評価され、早期退出者が抑制NAVで不利になる。
- **B-1 PoC による反証（`ProfitStreaming.t.sol::test_B1_shutdownJIT_*`）**: `_lockedProfit` を shutdown でクリアすると、
  guardian の shutdown tx は mempool 可視なので、攻撃者が**その直前に抑制NAVで安く deposit → shutdown 後に redeem**
  （lock は shutdown 中 waived）することで解放益を窃取できる。実測抽出額:

  | 攻撃者 | 抽出額（報酬1,000に対して） |
  |---|---|
  | 同額ステーク | **≈500 USDC（50%）** |
  | 鯨 | **≈990 USDC（99%）** |

  クリアを外して線形unlockを維持すると**抽出は 0**。すなわち shutdown 中の NAV「抑制」は streaming が防ぐべき
  JIT を防いでいる**意図した挙動**であり、クリアはそれを破壊して JIT を再導入する。「早期退出者が不利」は損失ではなく
  **未 vest 分**で、vault 内に価値保存され残存ホルダーへ8hで vest する。
- **結論**: R8-1 は NON-FINDING。**shutdown はソース変更なし**（クリアしない）。将来「再修正」されないよう
  `setEmergencyShutdown` に PoC 参照つきの根拠コメントを追加。
- **回帰**: `test_B1_shutdownJIT_equalStake_noExtraction` / `_whale_noExtraction`（抽出 ≤ 2）＋
  `test_R8_1_shutdown_preservesStreaming_rewardVestsToStayer`（streaming 維持と残存者への full vest を固定）。
- **mutation canary**: クリアを再導入すると B-1 テストが失敗することを確認済み（抽出 500/990 に戻る）。

## R8-2 — Pendle withdraw の Leg 2 が router 戻り値を信頼（Low／bounded）

- **箇所**: `src/adapters/PendlePTAdapter.sol` `withdraw` Leg 2。deposit 側は M-04 で全量を実残高デルタから導出するのに、exit 側だけ router の自己申告 `susdeOut` を使用していた（非対称）。
- **内容**: `susdeOut` が Leg 2 のスワップ数量と `usdcMin` 算出の両方に使われる。router が over-report すると `_swapVia` が保有量を超える sUSDe を pull しようとして revert（withdraw DoS）。under-report すると Leg 2 の slippage floor が実勢より緩む。
- **発火条件（休眠の根拠）**: Pendle Router V4 が戻り値を偽った場合のみ。router は信頼された不変コントラクト。
- **修正**: router 呼び出し前後の sUSDe 実残高デルタで `susdeOut` を算定し `require(susdeOut >= susdeMin)`（deposit 側の `ptGained >= minPtOut` と対称）。stack-too-deep 回避のためデルタ計測はブロックスコープ化。
- **回帰**: `test/PendlePTAdapterAdversarial.t.sol::test_R8_2_exitUsesBalanceDelta_notRouterOverReport` ／ `test_R8_2_fullExit_robustToOverReport`（`MockPendleRouter.setReportBps` で over-report を注入）。

## B-2 — 兄弟経路の全掃（2マトリクス）

「1箇所直して終わり」にしないため、全アダプター×全レグを2軸で全掃。

### (i) 外部戻り値の信頼マトリクス（M-04 が deposit 以外に届いているか）

swap 系レグ（Ethena 全ホップ・Pendle deposit 両レグ＋ withdraw 両レグ=R8-2後）はすべて **balance-delta**。
vault の recall/migration も `require(received>=toWithdraw)` の実測 guard を持つ。残る **TRUSTED-RETURN** は：

| # | 箇所 | 判定 | 対応 |
|---|---|---|---|
| Gap#3 | `VenusUSDTAdapter.withdraw` partial 分岐 `withdrawn=assets`（drain-all 分岐は実測なのに非対称） | **漏れ（低・DoS限定）** | **修正**：両分岐を USDT 実残高デルタに統一 |
| Gap#2 | `AaveV3USDCAdapter.withdraw` `withdrawn=aavePool.withdraw(...)` | **許容** | 資金は recipient(vault) へ**直送**・戻り値は会計に非消費・vault が実測 → コメント明記（「信頼された不変契約だから」ではなく「消費側が実測」が根拠） |
| Gap#1 | `setEmergencyShutdown` recall が delta guard なしで `_totalDebt=0` | **許容** | `_totalDebt` は簿記補助（`totalAssets()` は実残高由来）・activeAdapter 保持で退出時 `_recallFromAdapter` が実測 |
| Gap#4 | 各種評価 mark（`totalAssets`/`convertToAssets`/TWAP/`exchangeRateStored`） | **許容** | 価格は delta 化不能。TWAP-not-spot＋par cap（Pendle）/ haircut＋内部 rate（Ethena）/ stale-conservative（Venus）＋ pull 時 delta guard で構造防御 |

### (ii) 状態リセット非対称マトリクス（shutdown / force-detach / migration / reopen × 会計state）

| 非対称 | 判定 |
|---|---|
| `_lockedProfit`/`_lastReport`：lossy force-detach はクリア・shutdown は非クリア | **意図的**（R8-1 の JIT 論拠。detach は退出する adapter に対し mark を realize、shutdown は保持で JIT を開かない） |
| `depositsPaused`：detach は set・shutdown は非 set | **意図的**（shutdown は `emergencyShutdown` 直接 gate で deposit 遮断＝冗長回避） |
| `depositsPaused`：migration は自動クリア・idle 化後は `reopenDeposits` 手動 | **意図的**（healthy adapter 付替が再評価＝再開の意思） |
| `_totalDebt`：setAdapter は無条件0・shutdown は成功時のみ | **意図的/benign**（fallback mark として retained adapter と整合） |
| `_lockedUntil`：どの操作もリセットしない | **意図的**（shutdown が全 read 地点で lock を waive・第三者 re-lock は H-3 で不可） |
| **`_lastHarvestTimestamp`（fee anchor）：4操作いずれもリセットしない** | **漏れ（A6・軽微/有界）→ 修正** |

### A6 — 管理手数料 anchor が shutdown で凍結されない（Low／有界・修正）

- **内容**: `_collectFees` は `elapsed = now - _lastHarvestTimestamp` で **shutdown 窓も含めて** AUM 手数料を課金。次の退出時、破綻/idle 期間分まで退出ユーザーが希薄化される（`feeRecipient` へ mint）。上限 `MAX_MANAGEMENT_FEE=500`（5%/yr）・再分配的（価値消失でなく LP→feeRecipient）ゆえ軽微だが、非productive窓の課金は最も正当化しにくい。
- **修正（※手数料ポリシー変更＝veto 可）**: `setEmergencyShutdown(true)` で live のうちに `_collectFees()` して pre-shutdown 分を crystallize、`_collectFees` に `if (emergencyShutdown) return 0;` を追加して shutdown 中は課金凍結、再開時に anchor を now へリセットして shutdown 窓を **waive**（遡及課金しない）。`setManagementFee` の anchor ガード（L516-518）と同型。
- **回帰**: `SIXXVault.t.sol::test_B2_shutdown_waivesManagementFeeWindow`（pre-shutdown crystallize＋shutdown 窓非課金＋再開後 accrual 再開）。
- **回帰(Gap#3)**: `VenusUSDTAdapter.t.sol::test_B2_partialWithdraw_reportsRealDelta_notAssumedInput`（`MockVUSDT.setDeliverBps` で 90% 配布→デルタ報告・DoS 回避）。

## B-3 — Step 0 / fork（未了・この環境では OPEN）

- **fork 面**: 当環境に RPC 未設定（`ARB/ETH/BNB_RPC_URL` すべて unset・`.env` なし）。`EthenaSUSDeAdapterFork` / `PendlePTAdapterFork` / Aave・Venus の *ForkTest は setUp で revert＝**未検証**。**R8-2 は Pendle Router 実挙動に関わるため fork 無しでは検証が閉じない**。Codespaces secrets 設定済環境での再実行が必要。
- **Step 0**: mutation 偽kill の波及調査 / クリーンツリー・ガード / ゲート回帰テストは**隔離 worktree の別セッション**が担当中。結果が出るまで本差分の測定値（統計・kill率等）は**暫定**。

> **収束していない。** B-3（fork 実行・Step 0 完了）が残るため、main マージ・再凍結・ハンドオフ束再生成は**未実施**。

## 検証（mutation canary）

ソースの2修正のみ pre-fix に戻すと、追加した3テストはすべて失敗（空振りでないことを確認）:

| テスト | pre-fix の失敗内容 |
|---|---|
| `test_R8_1_shutdown_clearsLockedProfit_noSuppressedExit` | `locked profit cleared on shutdown: 1000000000 != 0` |
| `test_R8_2_exitUsesBalanceDelta_notRouterOverReport` | `ERC20InsufficientBalance`（予測どおりの DoS） |
| `test_R8_2_fullExit_robustToOverReport` | `ERC20InsufficientBalance` |

fix 適用後は全 283 件（非 fork）グリーン。

## 情報項目（非修正）

- shutdown 中も management fee が退出ユーザーから徴収される（`SIXXVault.sol:146-153`）— ガバナンス判断事項。
- `VenusUSDTAdapter` の NatSpec が testnet アドレスのみ・`estimatedAPY` は表示専用（会計非依存）。

## 次ラウンド候補（fork 必須・静的スコープ外）

- Aave `withdraw(max)` の高利用率時 revert 縮退（Arbitrum fork）。
- Venus `exchangeRateStored` staleness 窓の JIT gift 定量化（BSC fork）。
- reverting `redeem` 下の cross-adapter migration 原子性（force-detach への escape が runbook 化されているか）。
