# decisions.md — sixx-vault 決定台帳

> 目的: オーケストレーション/監査/デプロイに関わる **確定した決定と未決の論点** を1か所に記録する制御文書。
> 発端: 2026-07-16 の vault キックオフ時、参照先 `memory/decisions.md` が repo に不在だったため本ファイルを新設。
> 記法: 各項目に **状態**(CONFIRMED / OPEN / PENDING-HUMAN)・日付・根拠(repo 証跡)を付す。
> 境界: broadcast / 資金移動 / register / setAdapter / execute / activate = 人間 SHIN のみ。エージェントは記録・read-only・draft まで。

---

## D-A(CONFIRMED 2026-07-16 SHIN)— Ethena go-live / activate = レール完成(ユーザー未開放)
- **状態**: CONFIRMED。**activate 実行済(レール完成)**。ただし**ユーザー開放は外部監査後の方針を維持** = UI は「準備中」ゲート継続。
- **SHIN 提示の確定事実**:
  - `executeBatch` 実行済 — Safe→Timelock `0x8Cd71c…9895`、nonce 13、Success、**2026-07-16 19:03:59 JST**。
  - `registerAdapter` + `setAdapter` 確定 — **Vault `0xb7bD3E44…D8df` が Ethena adapter `0xbf555b98…54ec` に接続**。`activeAdapter = adapter` 想定。
### provenance 突き合わせ(2026-07-16 完了)= live ソース特定 + 3つの gate 所見
`broadcast/DeployEthenaAdapter.s.sol/1/` に **2つの mainnet deploy run** が記録されている(両方 chain 1・**同一 source commit `6bfe816`**):

| run file | timestamp | commit | 内容 | 状態 |
|---|---|---|---|---|
| `run-1783670478779.json`(#1) | …478779 | `6bfe816` | Timelock `0x8cd71c5a…9895` / Registry `0xf49ca40f…3473` / **Vault `0xb7bd3e44…d8df`** / **adapter `0xbf555b98…54ec`** | **← LIVE / activate 済**(SHIN 提示と完全一致) |
| `run-1783671828541.json`(#2)=`run-latest` | …828541 | `6bfe816` | Timelock `0x2ae6b837…` / Registry `0x0f44fc95…` / Vault `0x933537d1…` / adapter `0x896becfd…` | orphan(未 activate) |

**所見①(要修正)**: `run-latest.json` は **#2(orphan)** を指す。live システムは **#1**。deploy-gate/外部監査人が `run-latest` を信頼すると **非 live アドレスを掴む**。→ live=#1 を明示する注記/latest 修正が必要。
**所見②(good)**: 両 run とも **同一 source commit `6bfe816`**(2026-07-10「PendlePTAdapter terminology-guard 是正」)。∴ 監査対象ソースは source レベルでは一意。
**所見③(要判断・重要)**: **`6bfe816` は未タグ**(`audit-freeze-*` のいずれでもない)。かつ**現凍結 `audit-freeze-00e90cc`(0de26e7)から乖離大**: `SIXXVault.sol` 517行 / `EthenaSUSDeAdapter.sol` 49行 / `AdapterRegistry.sol` 33行差。→ **live レール(6bfe816)は round-8 v2 ハードニング(force-detach / F-guard 等)を含まない**。

### 是正決定(CONFIRMED 2026-07-16 SHIN)— 旧 live = 廃棄・監査は最新ハードニング版に一本化
- **旧 live #1(`0xb7bd3e44…`/`0xbf555b98…`・`6bfe816`・pre-hardening)= 廃棄扱い**。監査もしない・launch もしない(ユーザー未開放を維持)。#2 orphan も廃棄。
- **監査/production は最新ハードニング版に一本化**:draft 集約 `audit/scope-core-ethena-pendle`(P3 復元込み)を SHIN が **再凍結タグ → 外部監査 → その版を mainnet 再デプロイ + Timelock 結線 = production レール**。
- **run-latest 是正 済(2026-07-16)**: `broadcast/DeployEthenaAdapter.s.sol/1/PROVENANCE_NOTE.md` を追加 — run-latest が #2 orphan を指す点・#1/#2 とも `6bfe816`=廃棄版である点を明記。JSON は機械可読性のため非改変(companion note で注記)。production デプロイ時に新 broadcast を追加し run-latest を production へ更新する旨も記載。

## D-B(OPEN)— 外部監査ベンダーの選定・発注
- **状態**: OPEN(SHIN 決定待ち)。**repo にベンダー名・RFP・engagement letter は無し**。
- **repo 証跡**: 外部監査は「実装ハードニング最終形(②③④=profit-streaming/fee crystallize/permit forwarder 後)に **1回実施予定**」(`audit/README_FOR_REVIEWER.md:121`)。「外部監査(**SHIN 発注**)」(`audit/SLITHER_TRIAGE.md:42`)。repo の「監査」文書群は内部 adversarial(6エージェント等)であり外部ベンダーではない。
- **決定事項(SHIN 記入待ち)**: ベンダー名 / 発注時期 / 予算 / 提出コミット(=再凍結タグ)。
- **未記入**: <!-- SHIN: ベンダー・時期をここに記入 → 状態を CONFIRMED へ -->

## D-C(CONFIRMED 2026-07-16 SHIN)— 外部監査スコープ = 中核4契約 + Ethena + Pendle(Morpho/USDY 順次)
- **状態**: CONFIRMED。**監査スコープ = 中核4契約 + Ethena + Pendle**。Morpho(ERC4626)/ USDY は**順次**(後続ラウンド)。
- **理由**: **Ethena は mainnet activate 済 = 資金先**ゆえ、**未監査のままユーザー開放しない**(だから今回スコープに含める)。Pendle も同時に satellite として含める。Morpho/USDY はまだ資金先でないため順次でよい。
- **実行順序(SHIN 確定)**: **① Pendle PR#2 条件クリア → ② 新アダプター(Ethena+Pendle)を監査ブランチに集約(凍結 core 上に載せる)→ ③ 再凍結(新タグ)→ ④ 発注**。②③④のうち再凍結・発注は人間 SHIN、集約は draft/ブランチまでエージェント可。
- **進捗**:
  - ① **Pendle PR#2 条件クリア済**(2026-07-16、`feat/pendle-pt-adapter` `7a8e151`:loaded-slippage fail-close fork 6 green + 較正 doc。テスト/doc のみ・未マージ)。→ **② 集約に進める状態**(マージ自体は人間)。
  - **重要リンク(D-A provenance)**: live Ethena レールは `6bfe816`(pre-hardening・未タグ)。監査対象は**②で集約する凍結 aggregate(round-8 v2 ハードニング込)** になるため、**live 6bfe816 とは別ソース**。∴ 監査後に**ハードニング版 Ethena を再デプロイ**し、`run-latest`/gate を新デプロイに一致させるまで **live 6bfe816 はユーザー未開放(準備中)を維持**。
- **`audit/SCOPE.md` 更新要**: 現行は凍結 `9fa9796`(core のみ)。②の集約・再凍結時に SCOPE を「core4 + Ethena + Pendle」へ拡張し新凍結タグに差し替える(mainnet-gate 要件)。

### ② 集約の技術所見(2026-07-16 read-only 調査)= **単純マージ不可・要 SHIN 判断**
ベース候補と Pendle の実状態:
- **集約ベース = `audit/round8-hardening`**(= freeze `audit-freeze-00e90cc` src + docs、hardening markers=19、Ethena 込)。**`main`(d961dfc)は markers=9 でハードニング不足=ベース不適**。
- ベース上の Pendle は **escalate#1 前の旧版**(`recallHaircutBps` 無し)。escalate#1 版は `feat/pendle-pt-adapter` にあるが **pre-hardening 旧 core(markers=0・SIXXVault 517行差)上**で開発。
- ∴ `git merge feat/pendle-pt-adapter` は **ハードニング core を旧版へ巻き戻す**(危険)。正解は **escalate#1 の Pendle *アダプタ+テスト* だけをハードニング core へ graft**。

**退出モデルの意味論差(重要)** — ハードニング core は escalate#1 開発時の core と退出仕様が変わっている:
| 経路 | 旧 core(escalate#1 前提) | ハードニング core(ベース) | escalate#1 との両立 |
|---|---|---|---|
| 移行 setAdapter(≠0) | strict `require(received≥adapterBal)` | **同左 strict**(:574) | ✅ 両立(fail-close 維持) |
| setAdapter(0) | strict revert | **force-detach best-effort・never revert**(:728-733) | ⚠️ テスト不整合(revert 期待が崩れる) |
| ユーザー退出 withdraw/redeem | strict revert on shortfall | **`_exitRealize` best-effort・NEVER revert**(:343, F-guard :390-400) | ⚠️ adapter の fail-close revert を core が try/catch 吸収 → **payout=0・share 保持**(revert しない) |

**結論**:
- **アダプタ本体(`PendlePTAdapter.sol` escalate#1)はハードニング core と機能的に両立**(fail-close revert を core が吸収し「payout=0・持分保持」に変換=資金は安全)。
- ただし **escalate#1 の全 Pendle テスト**(`PendlePTAdapterVaultFork` / 新 `LoadedSlippageFork` / `Fork` / `Unit`)は **旧 strict-revert 前提**で書かれており、**ハードニング退出モデル(payout-0/持分保持・force-detach)に合わせて書き換えが必要**。単純 graft では setAdapter(0)/フル退出/部分退出の revert 期待テストが落ちる。
- **要 SHIN/architect 判断**: escalate#1 の fail-close が **force-detach + F-guard とどう合成されるべきか**(例: 満期前 Pendle 位置を force-detach で write-off する設計が許容か=CLAUDE.md「discrete-harvest 再検証」と同系の残余ストランド論点)。これは監査済退出モデルに触れるため、テスト書換前に方針確定が要る。
- **未着手(意図的)**: 危険な巻き戻しマージも、退出モデルに反する機械的 graft も**実行していない**(read-only 調査に留めた)。

### ② 集約 完了(2026-07-16)= draft ブランチ `audit/scope-core-ethena-pendle`(`b6c72f7`)push 済・未マージ
- **architect 裁定**(独立):合成は正しく安全 = **テスト期待値の書換のみ・アダプタ改修不要**(退出モデル面)。adapter の fail-close revert を hardened core の `_exitRealize`(best-effort・never-revert)が吸収 → ユーザー経路 payout-0/持分保持、`setAdapter(0)` force-detach、移行(≠0)のみ strict revert 維持。`harvest()` no-op ゆえ discrete-harvest トラップ非該当(`_lockedProfit` 常時0)。満期前 PT の force-detach write-off は許容(PT は detached adapter に保持・回収可)。
- **graft 実行**: escalate#1 `PendlePTAdapter.sol` + Deploy script + 4テストを **ハードニング core+Ethena(base)へ graft**。旧 `PendlePTAdapterAdversarial.t.sol` 除去。interface/ctor/registerAdapter は base と互換(graft 不要)。
- **テスト書換(裁定準拠)**: `LoadedSlippageFork` = absorbed-to-0 / force-detach / migration-revert / 柱4 回収。`VaultFork` par partial = best-effort 1-unit 端数許容。`Unit` twap テスト = 復元した 15min 下限。
- **★ セキュリティ退行を発見・修正(SHIN 承認のコード変更)**: escalate#1 が **Part B P3(TWAP≥15min)ハードニングを緩めて `>0` にしていた**(検査もテストも feature で欠落)。監査前に **`require(twapDuration_ >= 900, "ADAPTER: twap < 15min")` へ復元**。escalate#1 全テスト(TWAP=900)は緑・zero 拒否維持。テスト緩和(退行受容)は SHIN が明示的に却下。
- **緑**: 非 fork **381**(core/Ethena/hardening/Pendle Unit 含む)+ Pendle fork **25**(VaultFork 6 + LoadedSlippage 7 + AdapterFork 12)。
- **残(人間 SHIN)**: ③ 再凍結タグ付与(`audit/SCOPE.md` の LoC 表 `wc -l` 更新 + タグ)→ ④ 外部監査発注。`mainnet-gate` は再凍結タグ=監査提出版=(監査後)再デプロイの一致を要求。

### item5 USDY(scope 確定・2026-07-16 着手可)= 設計スカウティング中(コード未着手)
- スコープ D-C: 中核4+Ethena+Pendle に**順次** Morpho/USDY。USDY は監査ブランチ集約のタイミングで集約予定。
- **着手前に確定要の設計論点(net-new・盲目コード不可)**: ①変種(USDY 価格累積型 vs rUSDY rebase 型 — rebase は adapter の balance ベース totalAssets 前提に影響)②チェーン(mainnet / Mantle 等)③エントリ/退出(Ondo mint/redeem は KYC・40日ロック等の制約 vs DEX 流動性=item5 の想定)④**transferability/allowlist(KYC)**= USDY は譲渡制限あり得る → adapter が保有可能か・permissionless vault との整合(**潜在ブロッカー**)⑤ valuation/oracle(Ondo 価格源)。
- **進行**: 設計スカウティング エージェント起動(現物調査+既存アダプタ流儀での設計+要決定+fork テスト計画・**コード未着手**)。結果は本ファイルに追記し SHIN 判断へ。

---

## 記録(参考・エージェント read-only 確認)
- **item 1(Ethena provenance を main へ commit)= スキップ確定**(2026-07-16 SHIN 承認)。理由: commit 対象 untracked 0 件 + main 凍結(`audit-freeze-*`)。
- **Pendle escalate#1 = 反映済**。`feat/pendle-pt-adapter` tip `674876a` が ARCH_RULING を実装(A型 recall haircut + floor 同値化)。

### B — 各ブランチ build/test 緑チェック(2026-07-16, worktree 隔離)= 全緑 ✅ / item7 実測クローズ
| branch | build | non-fork tests | fork PoC |
|---|---|---|---|
| `feat/pendle-pt-adapter` | GREEN | 188 / 0 | **18/18**(AdapterFork 12 + VaultFork 6) |
| `feat/curve-stableswapper` | GREEN | 120 / 0 | — |
| `feat/dca-scheduler` | GREEN | 153 / 0 | — |
| `feat/erc4626-morpho-adapter` | GREEN | 55 / 0 | — |
- 手法(改善版): 各ブランチ専用 `git worktree`(detached)に `lib/` を symlink 共有(submodule pin 全一致を確認済)→ `forge build` + `forge test --no-match-contract Fork` → worktree 破棄。**main 作業ツリーは不可侵**(前回 in-place 方式の out/cache 汚染を解消)。

### C — Pendle PR#2 go/no-go = **GO-with-conditions**(独立敵対レビュー確定)
- **fork PoC 追試**: AdapterFork 12 + VaultFork 6 = **18/18 green**(worktree・`--fork-url $ETH_RPC_URL`)。
- **不変条件 = コードで確認済**: 単一 `_navFloor`(:498-501, TWAP を par で cap)を `totalAssets()`(:341-346)と `withdraw()` フル退出 min-out(:376-380, sUSDe→USDC swap :414 が `>=navPt` 未達で revert)が**共有** → vault が `withdraw(adapterBal=navPt+idle)` を呼ぶと delivered `>= navPt+idle = adapterBal` → M13-16 ガード恒真、未達は fail-close(資金移動なし)。idle 両側整合・truncation 全て vault 有利。**Critical/High バグ無し**。
- **所見(by-design トレードオフ)**:
  - [Med] tight/zero haircut で fail-close DoS 面: `recallHaircutBps` が実 round-trip 未満だとフル recall / `setAdapter` 移行が常時 revert(=0 で確実、上限 3%)。**流動性は off-chain 較正の正しさに依存**。
  - [Med] 部分退出も個別 fail-close(フルへのフォールバック無し)→ UX 層へ申し送り。
  - [Low] PT→sUSDe hop はルータ報告値を信頼(end-to-end floor で安全側・余剰 sUSDe は rescue 可)。[Info] 最終株 redeem 後の orphaned dust(ERC4626 virtual-share 一般性質)。governance setter は atomic+nonReentrant で in-flight 退出を壊さない。
- **マージ条件(コード修正ではない)= 2026-07-16 対応済(PR#2 draft-ready)**:
  - `feat/pendle-pt-adapter` に **`7a8e151`** を push(テスト/doc のみ・`PendlePTAdapter.sol` 及び production src 無改変・**未マージ**)。
  - (a) **loaded-slippage fail-close fork テスト追加** = `test/PendlePTAdapterLoadedSlippageFork.t.sol`(6, 全 green): sUSDe→USDC 脚に haircut 超 slippage(25%)を注入し、**フル redeem / 部分 withdraw / setAdapter(0) / setAdapter 移行**が実 vault M13-16 ガード経由で **fail-close(revert・state 無変化)** を実証。par control(slip=0)で「失敗は slippage 起因でハーネス由来でない」を証明。**3% cap でも深 slippage 市場は fail-close**(gap ② tie-in)。
  - (b) **haircut 較正手順 doc** = `docs/operations/pendle-haircut-calibration.md`: `recallHaircutBps ≥ 実測フル退出ラウンドトリップ(bound size)`、3% cap の対 AUM 検証要件、under-calibration の帰結(退出/移行 fail-close)、UX 申し送り。
  - **残テストギャップ(任意・後続)**: ④最終株 redeem 残余 dust ⑤満期跨ぎ(pre→warp→post)。
- broadcast/register/setAdapter/activate = SHIN のみ。**PR#2 は draft-ready(マージは人間)**。

### item-7 不整合(記録)
- **feature ブランチが `out/`・`cache/` を追跡したまま**(untrack `935fd12` は本ブランチのみ)。worktree 方式では無害(隔離)だが、各 feature ブランチにも同 untrack を適用すべき(要 commit=別途 SHIN 承認)。
- **D-A provenance 不整合**(上記): live activate アドレス ≠ repo broadcast 記録アドレス。要突き合わせ。
