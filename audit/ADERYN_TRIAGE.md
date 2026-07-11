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

---

## Aderyn 信頼性の確定（2026-07-12・第2独立レビュー追試）

### 1. 完走判定（クラッシュ無し・決定的）

| 項目 | 結果 |
|---|---|
| バージョン（ピン留め） | **aderyn 0.6.8** |
| `aderyn .` exit code | **3/3 run とも exit=0（完走）** |
| High/Med 件数の決定性 | 3/3 run とも **High=1 / Med=0**（決定的） |
| `reports/aderyn.log` | 正常終了（"Report printed to …/aderyn-report.md"）。**panic / fatal / backtrace 皆無** |

→ 現行環境で Aderyn は**安定完走**。よって「動く版へのピン留め」＝**0.6.8** を正とする。
将来 0.6.8 が壊れた場合の退避は下記ゲート仕様が自動で担保（PASS にならない）。

### 2. ゲート仕様（クラッシュ run を PASS 根拠にしない保証）

`scripts/contract-audit.sh` Stage 7 は **PASS を出す条件を全て AND** で判定する：
**(a) report ファイルが存在 ＋ (b) パース可能な "Issue Summary" 表がある（`FOUND`）＋
(c) High/Med がベースライン以内 ＋ (d) `aderyn` exit==0**。

したがってクラッシュ／不完全 run は必ず以下のいずれかで、**PASS には決してならない**：
- report 無し → **FAIL**
- report あるが Issue Summary 無し（途中クラッシュ）→ **FAIL**（`MISSING` 検出）
- exit≠0 だが report/summary はある → **WARN**（PASS ではない）
- High/Med がベースライン超過 → **FAIL**

**Slither（Stage 6）を静的解析の主ゲート**（全 severity の baseline diff ＋ 危険検出器カバレッジ）とし、
**Aderyn は副次的 cross-check** に位置づける（本ファイル §cross-check 参照）。

### 3. Slither との cross-check（High-1 = reentrancy FP の独立裏取り）

Aderyn High-1（reentrancy 15 インスタンス）を、同一関数に対する **Slither** の判定と突き合わせた
（`reports/slither.log`）。危険検出器 **`reentrancy-eth`（＝実際に exploitable な reentrancy）はコードベース全体で 0 件**。

| Aderyn High-1 の箇所 | Slither の対応 | 一致 | 判定 |
|---|---|---|---|
| `SIXXVault.setAdapter`（9 inst） | `reentrancy-no-eth`/`-benign`/`-events`/`-balance` で検出（**`reentrancy-eth` ではない**） | ✅ 両者が検出・共に非 exploitable 区分 | **FP**（`onlyGovernance`＋`nonReentrant`＋registry whitelist 済 adapter・CEI 整合） |
| `SIXXVault.harvest`（3 inst） | `reentrancy-benign`/`-events` で検出（非 exploitable） | ✅ 両者検出 | **FP**（`nonReentrant`・profit は balance-delta） |
| `AaveV3USDCAdapter` / `EthenaSUSDeAdapter` / `VenusUSDTAdapter` の constructor（各 1・計 3 inst） | **Slither は非検出**（constructor は再入不能と認識し reentrancy 対象外） | ⚠️ Slither はそもそも所見化せず＝**Aderyn の過剰報告**を裏取り | **FP**（constructor＝デプロイ完了前で再入経路が存在しない） |
| （コードベース全体） | **`reentrancy-eth` = 0 件** | ✅ 両ツール一致 | 実 exploitable reentrancy **なし** |

**cross-check 結論**：Aderyn High-1 の 15 件は、①Slither も同関数を非 exploitable 区分で検出（setAdapter/harvest）
＝ガード有りの FP、②Slither が所見化すらしない（3 constructor）＝Aderyn 固有の過剰報告、のいずれか。
**両ツールとも exploitable reentrancy（`reentrancy-eth`）は 0**。→ **High-1 は FP 確定**。ただし静的解析ツールの
限界を踏まえ、**外部監査で reentrancy の独立確認を依頼**（`README_FOR_REVIEWER.md` §レビュー重点に明記）。
