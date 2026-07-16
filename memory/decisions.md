# decisions.md — sixx-vault 決定台帳

> 目的: オーケストレーション/監査/デプロイに関わる **確定した決定と未決の論点** を1か所に記録する制御文書。
> 発端: 2026-07-16 の vault キックオフ時、参照先 `memory/decisions.md` が repo に不在だったため本ファイルを新設。
> 記法: 各項目に **状態**(CONFIRMED / OPEN / PENDING-HUMAN)・日付・根拠(repo 証跡)を付す。
> 境界: broadcast / 資金移動 / register / setAdapter / execute / activate = 人間 SHIN のみ。エージェントは記録・read-only・draft まで。

---

## D-A(PENDING-HUMAN)— Ethena go-live / activate の実状態確認
- **状態**: 人間 SHIN が Etherscan で確認中(エージェントは RPC 不使用のため確証不可)。
- **repo 証跡**: `broadcast/DeployEthenaAdapter.s.sol/1/run-latest.json`(chain 1 = Ethereum mainnet, ≈2026-07-09)は **CREATE(デプロイ)のみ**。
  - TimelockController `0x2ae6b837f07fb56da70d460c483a6ffcf45ac90b`
  - AdapterRegistry `0x0f44fc955357655721dc2c4b15a31dffbee9d9c2`
  - SIXXVault `0x933537d1be32a85a80d370e5e035f29f0d415af6`
  - EthenaSUSDeAdapter `0x896becfd1556de5e64d9df6465f83369a7310104`
- **全 ref を検索して `setAdapter`/`register`/`isActive`/`executeBatch`/`activate` の broadcast 記録は 0 件**。
  → repo 事実としては **デプロイ済・未 activate(準備中)**。ただし Safe/Timelock を forge broadcast 以外で実行していれば痕跡は残らない。
- **確定に必要**: SHIN が (i) `registry.isActive(0x896b…)` / `vault.activeAdapter()` の Etherscan 値、または (ii) activate/executeBatch の tx ハッシュ を提示 → 本項目を CONFIRMED に更新。

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

### B — 各ブランチ build/test 緑チェック(2026-07-16, 非 fork)= 全緑 ✅
| branch | build | non-fork tests |
|---|---|---|
| `feat/pendle-pt-adapter` | GREEN | 188 passed / 0 failed |
| `feat/curve-stableswapper` | GREEN | 120 passed / 0 failed |
| `feat/dca-scheduler` | GREEN | 153 passed / 0 failed |
| `feat/erc4626-morpho-adapter` | GREEN | 55 passed / 0 failed |
- 手法: クリーン作業ツリーで逐次 in-place checkout → `forge build` + `forge test --no-match-contract Fork` → HEAD 復元。

### C — Pendle PR#2 go/no-go = **GO(条件付き)** ✅
- **fork 検証(live ETH mainnet)**: `PendlePTAdapterFork` 12 passed(`--fork-url $ETH_RPC_URL`)+ `PendlePTAdapterVaultFork` 6 passed(in-code fork)。**Pendle 86/86 green 再現**(unit 68 + fork 12 + vault-fork 6)。
- **独立コード検証**: `totalAssets()` = `_navFloor(ptBal)+idle`(:297)、`withdraw()` の end-to-end min-out も **同一 `_navFloor`**(:342-352)。∴「報告 NAV = withdraw floor」が**同一関数で構造的に成立** → 退出完了時 `received ≥ 報告NAV` → SIXXVault M13-16 ガード恒真。市場が floor 未達なら revert(fail-close・資金移動なし)。Ethena adapter と同型。
- **GO の条件(activate 前に人間 SHIN)**: `recallHaircutBps`(既定 0.5%・上限 3%)を**実測ラウンドトリップ(市場インパクト+sUSDe→USDC 脚+TWAP-vs-spot クッション)以上**に較正。broadcast/register/setAdapter/activate は SHIN のみ。

### item-7 不整合(新規発見・記録)
- **feature ブランチが `out/`・`cache/` を追跡したまま**。untrack コミット `935fd12` は `audit/round8-hardening` のみに適用。→ 各 feature ブランチの checkout でビルド生成物が再追跡され、in-place build がツリーを汚す(force checkout で回避可)。各 feature ブランチにも同じ untrack を適用すべき(要 commit=別途 SHIN 承認)。
