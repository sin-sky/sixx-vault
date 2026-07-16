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
**所見③(要判断・重要)**: **`6bfe816` は未タグ**(`audit-freeze-*` のいずれでもない)。かつ**現凍結 `audit-freeze-00e90cc`(0de26e7)から乖離大**: `SIXXVault.sol` 517行 / `EthenaSUSDeAdapter.sol` 49行 / `AdapterRegistry.sol` 33行差。→ **live レール(6bfe816)は round-8 v2 ハードニング(force-detach / F-guard 等)を含まない**。SHIN 方針「全修正 → 外部監査 → mainnet 再デプロイ」に従うなら、live 6bfe816 は **pre-hardening のレール(dormant・ユーザー未開放)** と位置づけ、**production は監査済凍結を再デプロイ**し、そのソースにタグを付けて `run-latest`/gate を live に一致させる必要がある。**mainnet-gate.md「デプロイ対象=再凍結タグ=外部監査提出版と一致」は現状みたされていない**(deploy=6bfe816 未タグ ≠ freeze=00e90cc)。→ **D-C(監査スコープ)+ 再凍結の SHIN 判断が必要**。

## D-B(OPEN)— 外部監査ベンダーの選定・発注
- **状態**: OPEN(SHIN 決定待ち)。**repo にベンダー名・RFP・engagement letter は無し**。
- **repo 証跡**: 外部監査は「実装ハードニング最終形(②③④=profit-streaming/fee crystallize/permit forwarder 後)に **1回実施予定**」(`audit/README_FOR_REVIEWER.md:121`)。「外部監査(**SHIN 発注**)」(`audit/SLITHER_TRIAGE.md:42`)。repo の「監査」文書群は内部 adversarial(6エージェント等)であり外部ベンダーではない。
- **決定事項(SHIN 記入待ち)**: ベンダー名 / 発注時期 / 予算 / 提出コミット(=再凍結タグ)。
- **未記入**: <!-- SHIN: ベンダー・時期をここに記入 → 状態を CONFIRMED へ -->

## D-C(OPEN)— 監査スコープに新アダプターを含めるか
- **状態**: OPEN(SHIN 決定待ち)。**現行スコープは中核契約のみ**。
- **repo 証跡**: `audit/SCOPE.md:3` = 凍結 `9fa9796`(Round 7・core)。新アダプター **Ethena / Pendle / Morpho(ERC4626) / USDY** は別ブランチ・未マージで **現スコープ外**。元 RFP=中核4契約(SHIN 認識と一致)。
- **論点**: mainnet に既にデプロイ済みの Ethena 一式を **未監査のまま activate するか**、それとも SHIN 方針「全修正 → 外部監査 → mainnet 再デプロイ」に従い監査後に activate するか。`docs/operations/mainnet-gate.md` は「デプロイ対象=再凍結タグ=外部監査提出版と一致」を要求 → 新アダプターを含めるなら **スコープ拡張 + 再凍結タグ** が必要。
- **決定事項(SHIN 記入待ち)**: 含める新アダプターの集合 / 再凍結タグ / activate と監査の順序。
- **未記入**: <!-- SHIN: 含める/含めない と順序をここに記入 → 状態を CONFIRMED へ -->

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
