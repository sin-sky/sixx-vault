# 測定器の修正 — S0 (2026-07-12)

> Round 8 を回す前に**測定器そのもの**を直す。差分敵対リパスで 2 つの「計器が嘘をつく」欠陥が判明した:
> (1) mutation の**偽 kill**（`--match-contract '*'` 異常終了で全 mutant を kill 誤判定）、
> (2) 静的解析の**変異体汚染ツリー読み込み**（Gambit の mutant が src/ に残ったまま Slither/Aderyn が走り phantom High）。
> 同じツールチェーンで Round 8 を回しても壊れた結果が返るだけなので、先に計器を修理する。

- 対象 tip: src `9fa9796` / docs `dca47bf`。凍結 src 無改変。commit: 本 doc の HEAD 参照。

---

## S0-1 — mutation 偽 kill の波及調査

### 根本原因の切り分け（重要）
偽 kill を出したのは **本セッションの ad-hoc スクリプト `/tmp/runmut.sh`** で、`forge test --match-contract '*'` を
使っていた。`'*'` は正規表現として不正 → forge が異常終了（非ゼロ）→ 私の分類ロジックが「非ゼロ=kill」と
誤判定し、全 mutant を偽 kill していた（初版リパスの「89/89 kill」がこれ）。

**出荷ハーネス `scripts/mutation-test.sh` はこのバグを持たない**:
- 分類 invocation は `forge test --no-match-contract "Fork" ${MUTATION_MATCH:+--match-contract "$MUTATION_MATCH"} -q`。
- 看板 stat（1,090-mutant run）は **`MUTATION_MATCH` 未設定**で実行 → `--match-contract` は付かず、`'*'` 異常終了は起きない。

### 看板 stat「94.6% / 1090 / killed 1031 / survived 59」の検証可能性
- 生ログ（`reports/mutation/mutation-report.md`・`survivors.txt`・`gambit.log`）は **repo にも handoff 束にも未保存**
  （`reports/` は gitignore）。看板を設定した commit `76adb75` は **doc のみ**の変更で、実行ログを伴わない。
  → **as-run では検証不能**（＝ユーザー方針の「検証できない」ケース）。
- **論理的健全性（部分証明）**: 異常終了する invocation は survivor を 1 件も生まない（全件 kill 誤判定＝生存 0）。
  看板は **survived 59** と報告している ⟹ その 59 件では `forge test` が実際に走って PASS した ⟹ **crash 系 invocation ではない**。
  ∴ 看板は「健全な invocation で走った run」と内部整合。ただし exact 数（1031/59）は再現ログ無しでは確定できない。

### アクション: 硬化ハーネスでフル再実行（正しい invocation・ログ保存）
- ユーザー方針「検証できない → フル mutation を正しい invocation で再実行し、正しい数字に訂正」に従い、
  **canary 付き `mutation-test.sh` で `MUTATION_N=2000`（＝1090 全件, ダウンサンプル無し）/ `seed=0` を現 tip で再実行**。
- 現 tip のテストは初版比 +8（本リパス追加）＝ **現行テスト suite での authoritative な数字**を得る（960b707 の歴史値を上書き）。
- 結果と `mutation-report.md` を **evidence として commit**（単一ソース）。**看板は再実行値に訂正**（本 doc 末尾に確定値を追記）。
- ※ この環境は **2 コア**ゆえ 1,090×(recompile+suite)≈ 数時間。結果確定後に `README_FOR_REVIEWER.md`・`SCOPE.md`・
  `MUTATION_TRIAGE.md` の数字を一括更新し、必要なら handoff 束（dca47bf zip）を再生成する。

> **判定**: 看板の生成 invocation 自体は健全（偽 kill は ad-hoc script 由来で出荷ハーネスではない）だが、
> **as-run ログが無く exact 数は未検証**。→ **硬化ハーネスでフル再実行して数字を確定・訂正**する（進行中／確定値は末尾）。

---

## S0-2 — 静的解析の汚染再発防止（clean-tree guard）

### 追加した gate: `scripts/clean-tree-guard.sh` ＋ `contract-audit.sh` Stage 0a
Slither/Aderyn/Halmos/build/test を走らせる**前に**、以下なら **HARD FAIL で停止**（`|| true` で握りつぶさない・exit≠0=FAIL）:
1. **mutation 生成物の存在**: `gambit_out/` / `gambit_diff_out/` / `mutants/` ディレクトリ / `*.mutant`（lib/ 除く）。
2. **src/ の未コミット変更**: `git status --porcelain -- src` が非空（＝解析対象がコミット済ソースと不一致＝mutant 残留の疑い）。
   - git work tree でない場合（handoff 束の展開先）は git-dirty 検査を skip、artifact 検査は継続。

ライブ実証:
```
clean src           → CLEAN-TREE GUARD: clean … (exit 0)
gambit_out/ 設置     → CONTAMINATED — mutation artifacts present: gambit_out/ … (exit 1)
src/ を dirty 化      → CONTAMINATED — src/ has uncommitted changes … (exit 1)
```

### handoff 束の Slither/Aderyn が clean tree で再現することの確認
- `contract-audit.sh` フルゲート（clean tree）= **OVERALL PASS ✅**。うち
  **slither「no new High/Medium vs baseline」・aderyn「High=1(≤1)/Med=0(≤0), exit=0」**＝ triage 済 baseline と一致再現。
- 初版で見えた「Misused boolean @ Ethena:305」は、**背景 mutation タスクが mutant(`if(false)`) を src に置いた瞬間を
  Aderyn が読んだ汚染**と特定（clean tree で非再現）。→ **再現しない指摘＝汚染由来のみ。triage やり直し不要**。

---

## S0-3 — ゲート自体の回帰テスト（3 回目の false-pass を許さない）

### 追加した回帰: `scripts/measurement-guard.test.sh` ＋ `contract-audit.sh` Stage 0c
Stage 0b（on-chain guard 回帰）と同型。fake `forge`/`gambit`（fake `$HOME` で解決を奪う）で hermetic・高速。6 検証:

| # | 検証 | 期待 |
|---|---|---|
| A | dirty src/ → `clean-tree-guard` | **FAIL(exit1)** |
| B | mutation 生成物 → `clean-tree-guard` | **FAIL(exit1)** |
| C | clean tree → `clean-tree-guard` | **PASS(exit0)** |
| D | 分類 invocation が crash（regex エラー）→ `mutation-test.sh` | **ABORT(exit4)**（偽 kill を出さない） |
| E | 分類 invocation が 0 テスト（0-match）→ `mutation-test.sh` | **ABORT(exit4)**（偽 survive を出さない） |
| F | 健全な invocation → `mutation-test.sh` pre-flight | **PASS**（その後 gambit で停止 exit3） |

**全 6 green**（`contract-audit.sh` Stage 0c で PASS 記録）。

### 根本対策: `mutation-test.sh` の pre-flight canary
mutant ループ前に、**未変異 src で分類 invocation を 1 回実行**し
「(a) exit 0 かつ (b) 実行テスト数 > 0」を検証。偽らなければ abort(exit4):
- crash 系（`'*'` regex 等）→ (a) 失敗 → abort（全件偽 kill を防止）
- 0-match 系 → (a) は通るが (b) 0 テスト → abort（全件偽 survive を防止）

→ **偽 kill / 偽 survive の両クラスを、mutant を 1 件も走らせる前に検出して停止**。

---

## 完了状況

| 項目 | 状態 |
|---|---|
| S0-2 clean-tree guard（Stage 0a）＋ 回帰 | ✅ 実装・green・ライブ実証済 |
| S0-3 measurement 回帰（Stage 0c, A–F）＋ canary | ✅ 実装・全 6 green |
| `contract-audit.sh` 全ゲート（clean tree） | ✅ OVERALL PASS ✅（新 stage 込み） |
| handoff Slither/Aderyn の clean-tree 再現 | ✅ 一致（phantom は汚染由来と確定） |
| S0-1 看板 stat の確定 | ⏳ **硬化ハーネスでフル1090 再実行中**（確定値を本 doc・README・SCOPE に反映後クローズ） |
| 凍結 src 無改変 | ✅ |

> **Round 8 は S0-1 のフル再実行が確定するまで開始しない。**

---

## 確定値（フル1090 再実行の結果）

<!-- 硬化ハーネス（canary付き）による MUTATION_N=2000/seed=0/現tip の再実行結果をここに確定記載する -->
（再実行完了後に追記）
