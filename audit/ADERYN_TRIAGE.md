# Aderyn 静的解析 トリアージ — sixx-vault

> 区分: 🟢 done（解析＋全 High 件トリアージ）。2026-07-12（第2独立レビュー P-02）。
> ツール: **Aderyn 0.6.8** / solc 0.8.28 / EVM cancun。コマンド: `aderyn .`（`scripts/contract-audit.sh` Stage 7）。
> 対象: `src/`（16 ファイル / 1,575 nSLOC）。`lib/`・`test/`・`script/` は対象外。
> 結果（`reports/aderyn-report.md` の Issue Summary）: **High 1・Medium 0・Low 13**。

---

## 結論

**High 1 件は 100% 偽陽性（FP）。実セキュリティ問題ゼロ。** Medium 0。
唯一の High 検出器 `reentrancy-state-change-after-external-call`（15 インスタンス）は、
①`nonReentrant` 配下の関数、または ②コンストラクタ内代入 のいずれかで、いずれも再入経路が存在しない。

この判定は `contract-audit.sh` Stage 7 の **機械判定ゲート**で恒久化した：
Aderyn の "Issue Summary" 表から High/Medium 件数を抽出し、**トリアージ済みベースライン
（`ADERYN_HIGH_BASELINE=1` / `ADERYN_MED_BASELINE=0`）を超えたら FAIL**。ベースライン内なら PASS。
Aderyn 自体の異常終了はレポート有無で WARN/FAIL に分岐（`|| true` によるサイレント握り潰しを廃止）。
→ **新規の High/Medium が 1 件でも増えれば必ず赤くなる**（＝この triage が守るのは「既知 FP のみ」）。

---

## High-1 の全 15 インスタンス トリアージ

検出器: **H-1: Reentrancy: State change after external call**（"外部呼び出しの後に状態変更 → 再入の恐れ"）。
Aderyn は「外部呼び出し」と「状態変更」を関数内で機械的にペアリングするだけで、`nonReentrant`
ガードやコンストラクタ文脈を考慮しない。本 repo の 15 件はすべてそのどちらかで無害。

| # | 箇所（関数） | インスタンス | 判定 | 理由 |
|---|---|---|---|---|
| 1 | `AaveV3USDCAdapter` constructor | 1 | 偽陽性 | **コンストラクタ内**の state 代入（`asset`/`aavePool`/… ）。デプロイ完了前＝外部から再入する攻撃者が存在しない。`require(...)` の外部 read はチェック用。 |
| 2 | `EthenaSUSDeAdapter` constructor | 1 | 偽陽性 | 同上。`IStakedUSDeV2(susde_).asset()` 等の read はトークン集合の on-chain 検証。コンストラクタ＝再入不能。 |
| 3 | `VenusUSDTAdapter` constructor | 1 | 偽陽性 | 同上。`IVenusVToken(vToken_).underlying()` は asset 一致検証。 |
| 4 | `SIXXVault.harvest()` | 3 | 偽陽性 | 関数は **`nonReentrant`**。`adapter.totalAssets()`/`adapter.harvest()` 呼び出し後に `_lockedProfit`/`_lastReport` を更新するが、reentrancy guard で再入不可。profit は before/after の balance-delta で算定（戻り値非依存＝M13-16 同型）。 |
| 5 | `SIXXVault.setAdapter()` | 9 | 偽陽性 | 関数は **`onlyGovernance` ＋ `nonReentrant`**。呼び出し先は registry でホワイトリスト済み adapter（信頼モデル）または force-detach 時の旧 adapter（try/catch で隔離）。`activeAdapter`/`_totalDebt`/`depositsPaused`/`_lockedProfit`/`_lastReport` の更新順は CEI 整合。force-detach の `received` は実残高デルタで算定。 |

> 合計 15。危険検出器のうち **delegatecall / arbitrary-send / tx-origin / weak-randomness 等は 0 件**。
> Low 13 件（empty-block / large-literal / literal-instead-of-constant / state-var-shadow /
> modifier-once / nonReentrant-order / push0 / state-change-without-event / centralization /
> array-length-caching / unchecked-return / uninitialized-local / unspecific-pragma）は
> いずれも情報/様式/最適化クラスで、既存の `SLITHER_TRIAGE.md`・`AUDIT_PACKAGE.md §Slither`
> と同型（意図的設計・可観測性提案・gas 最適化）。ゲート対象外（Low は集計のみ）。

---

## 追補（2026-07-12・第2独立レビュー H-01/M-01 remediation 後）

- **H-01**（force-detach で totalAssets() が revert した場合も deposit 停止）: `setAdapter` の
  force-detach 分岐に `navReadOk` 追跡＋`depositsPaused=true` 強制＋`AdapterNavUnreadableOnDetach`
  イベントを追加。**同一 `nonReentrant setAdapter` 内**の追加なので High-1 #5 の FP クラスは不変（件数据え置き）。
- **M-01**（Pendle swapper 無期限 allowance 廃止）: `_swapVia` で swap 毎に exact-approve→0。
  外部呼び出し（`swapper.swap`）は元々 `deposit`/`withdraw`（`nonReentrant`）配下＝reentrancy 面で
  新規 High を生まない。`forceApprove(...,0)` は状態変更だが再入不能。

→ High=1 / Med=0 のベースラインは **据え置き**。実問題ゼロ。行番号は remediation で下方シフトするが、
本トリアージは**関数/クラス単位**で記述しているため影響なし（`reports/aderyn-report.md` は監査実行毎に再生成）。
