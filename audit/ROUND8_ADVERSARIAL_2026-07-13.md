# Round 8 — 内部敵対的リパス（2026-07-13）

> 基準: `main` tip（`9fa9796` のソース本体＝Round 7 凍結と同一）。solc 0.8.28。
> 手法: コア/Vault・Ethena・Pendle・Aave+Venus+wiring の 4 領域を独立に敵対的レビューし、
> 既知findings（H-1〜4 / M-1〜5 / F-1〜3 / L-*）の**外側**にある新規issueのみを抽出。

## 総括

- **新規 High/Critical はゼロ。** 既知findingsはすべて再プローブに耐えた。
- Ethena（Curve マルチホップ・slippage・cooldown・NAV 操作）と Aave+Venus+wiring（Venus error-code・USDT 非標準 ERC20・deploy の gov=Timelock 配線）は **clean**。指摘は doc nit のみ。
- 新規は防御的一貫性（defense-in-depth）の **休眠**項目が 2 件。いずれも**現行デプロイでは発火しない**が、correct-by-construction として本ラウンドで修正した。

## R8-1 — emergency shutdown が `_lockedProfit` をクリアしない（Low／将来 Med）

- **箇所**: `src/core/SIXXVault.sol` `setEmergencyShutdown`（force-detach パス `setAdapter` は `_lockedProfit=0` するのに shutdown は非対称）。
- **内容**: shutdown は withdraw lock を解除し全員に即時退出を促す（`maxWithdraw`/`maxRedeem` は shutdown 中に非ゼロ）。しかし `_lockedProfit` が残ると `totalAssets()` が最大 `PROFIT_UNLOCK_PERIOD`（8h）過小評価され、早期退出者は抑制された NAV で価格付けされる（ユーザー間の不公平な再分配、価値は保存され 8h で自己修復）。permissionless な `harvest()` で窓を再延長できる増幅経路も存在。
- **発火条件（休眠の根拠）**: discrete-reward アダプター採用時のみ。**現行4アダプター（Aave/Venus/Ethena/Pendle）は harvest() が no-op で `_lockedProfit` を一度も populate しない**（`ProfitStreaming.t.sol::test_harvest_noop_onContinuousAdapter_locksNothing` 参照）。
- **修正**: shutdown 起動時に `_lockedProfit = 0; _lastReport = block.timestamp;` を設定（force-detach と対称化）。現行アダプターでは実質 no-op。
- **回帰**: `test/ProfitStreaming.t.sol::test_R8_1_shutdown_clearsLockedProfit_noSuppressedExit`。

## R8-2 — Pendle withdraw の Leg 2 が router 戻り値を信頼（Low／bounded）

- **箇所**: `src/adapters/PendlePTAdapter.sol` `withdraw` Leg 2。deposit 側は M-04 で全量を実残高デルタから導出するのに、exit 側だけ router の自己申告 `susdeOut` を使用していた（非対称）。
- **内容**: `susdeOut` が Leg 2 のスワップ数量と `usdcMin` 算出の両方に使われる。router が over-report すると `_swapVia` が保有量を超える sUSDe を pull しようとして revert（withdraw DoS）。under-report すると Leg 2 の slippage floor が実勢より緩む。
- **発火条件（休眠の根拠）**: Pendle Router V4 が戻り値を偽った場合のみ。router は信頼された不変コントラクト。
- **修正**: router 呼び出し前後の sUSDe 実残高デルタで `susdeOut` を算定し `require(susdeOut >= susdeMin)`（deposit 側の `ptGained >= minPtOut` と対称）。stack-too-deep 回避のためデルタ計測はブロックスコープ化。
- **回帰**: `test/PendlePTAdapterAdversarial.t.sol::test_R8_2_exitUsesBalanceDelta_notRouterOverReport` ／ `test_R8_2_fullExit_robustToOverReport`（`MockPendleRouter.setReportBps` で over-report を注入）。

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
