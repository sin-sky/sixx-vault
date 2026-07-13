# 監査サマリ（メインスレッド確認用）— ERC4626Adapter (Morpho)

> このファイルは ERC4626Adapter（Morpho/Gauntlet USDC Prime）監査スレッドの**全成果物の統合インデックス**です。
> メインスレッドはまず本書を読み、末尾の **「メインスレッド確認チェックリスト」** で承認可否を判断してください。
> 個別の詳細は各レポートへリンクしています。

| | |
|---|---|
| 対象 | `sin-sky/sixx-vault` @ `feat/erc4626-morpho-adapter`（PR #1, OPEN・非draft） |
| 最新 commit | `980b2f4` |
| 監査者 | Local Claude (Opus) — 手動コードリーディング + Foundry PoC |
| 結論 | **v1 / v2 とも 🟢 条件付き GO**（活性化前ブロッカーあり・下記） |
| 重要状態 | v2 adapter `0x83E6…8a8D` は **deploy 済・登録済・未活性**。`activeAdapter` は **Aave のまま（資金未移動）** |

---

## 0. 全成果物（すべて push 済・他スレッド参照可）

| 成果物 | 内容 | commit |
|---|---|---|
| [`AUDIT_REPORT_erc4626_adapter_2026-06-02.md`](./AUDIT_REPORT_erc4626_adapter_2026-06-02.md) | **v1 監査**（本体ロジック・活性化 go/no-go） | `8c05530` |
| [`TEST_RESULTS_erc4626_adapter_2026-06-02.md`](./TEST_RESULTS_erc4626_adapter_2026-06-02.md) | テスト内容・結果の全記録 | `e2071ec` |
| [`AUDIT_REPORT_erc4626_adapter_v2_2026-06-03.md`](./AUDIT_REPORT_erc4626_adapter_v2_2026-06-03.md) | **v2 監査**（141行差分・post-deploy） | `980b2f4` |
| `src/adapters/ERC4626Adapter.sol` | 本体（rescue/isFullyExited 追加済） | `8c05530` |
| `script/RedeployERC4626Adapter.s.sol` | 再デプロイ用 3 ガバナンス操作 | `8c05530` |
| `test/ERC4626AdapterRegression.t.sol`（6本）/ `test/ERC4626AdapterV2PoC.t.sol`（7本） | 攻撃回帰・PoC | `8c05530`/`980b2f4` |

---

## 1. タイムライン（何が起きたか）

1. **v1 監査**（commit `828ecfe`）→ 判定 **条件付き GO**。Critical/High ゼロ。活性化方向は構造的に資金喪失不能を PoC 実証。推奨：L-1 rescue 追加・M-G1 migrate-out 対策。
2. **ハードニング**（commit `8c05530`）→ L-1 `rescue()` と M-G1 `isFullyExited()` を実装、回帰 6 本追加。
3. **本番再デプロイ**（ユーザー実行）→ v2 `0x83E6…8a8D` を ETH mainnet に deploy・register・旧 `0x4f6D…9ad2` を無効化。**`setAdapter` は未実行＝active は Aave 据置**。
4. **v2 監査**（commit `980b2f4`）→ post-deploy 検証。判定 **条件付き GO**。

---

## 2. 監査判定（v1 + v2 統合）

| 深刻度 | v1 | v2（差分のみ） | 統合状態 |
|---|---|---|---|
| 🔴 Critical | 0 | 0 | **0** |
| 🟡 High | 0 | 0 | **0** |
| 🟠 Medium | 1（M-G1：将来 migrate-out） | 1（V2-M1：M-G1 未強制） | **M-G1 系 = OPEN（手続き対応で可）** |
| 🟢 Low | 3（L-1/L-2/L-3） | 0 | L-1 **クローズ**／L-2,L-3 は外部依存・運用（喪失なし） |
| ⚪️ Info | 3 | 2 | 無害 |

### 確定した良い点
- **資金安全性**：活性化（Aave→Morpho）は **構造的に資金喪失不能**。最悪でも資金は vault に idle 退避し全額退出可（M-3 try/catch、PoC 実証）。
- **`rescue()` は安全（L-1 クローズ）**：原資産(USDC)と vault share(=元本)を**両ハード除外**、governance 限定、**再入は OZ `ReentrancyGuardReentrantCall()` で阻止**を PoC 実証。元本抜き取り経路なし。
- **再デプロイ script は安全**：3 操作のみ・`OLD != active` を assert・`setAdapter` 不呼出。

### ⚠️ メインスレッドが必ず認識すべき 1 点（V2-M1）
- **`isFullyExited()` は契約レベルで未強制**。view を足しただけで、本番 `SIXXVault.setAdapter`（**非アップグレーダブル**）は require しない。
- 影響：**本活性化（migrate-in）には無関係**。ただし**将来 Morpho を「出る」移行**を行うなら、スクリプトで `require(adapter.isFullyExited())` を `setAdapter` 前に必ず入れること（手続き的強制が唯一の担保）。
- PoC で「require が無いと illiquid adapter を切り離して資金 stranded」を実証済（可逆だが要注意）。

---

## 3. テスト結果（全体）

| スイート | テスト数 | 結果 |
|---|---|---|
| Unit `ERC4626AdapterUnitTest` | 21 | ✅ |
| Invariant `ERC4626AdapterInvariantTest` | 1（256 runs/3,840 calls） | ✅ **0 revert** |
| Regression `ERC4626AdapterRegressionTest` | 6 | ✅ |
| **v2 PoC `ERC4626AdapterV2PoC`** | 7（必須4 revert + 再入 + happy + M-G1未強制） | ✅ |
| Integration `SIXXVaultTest` | 20 | ✅ |
| **合計（非fork）** | **55** | ✅ **55/55 PASS・0 fail** |
| Fork（RPC 必須） | 4 contract | ⏸ **未実行**（活性化前ブロッカー） |

`forge build` 成功（Solc 0.8.28 / OZ v5.6.1）。

---

## 4. 活性化（setAdapter）前の必須ブロッカー

| # | ブロッカー | 状態 | 担当 |
|---|---|---|---|
| 1 | **オンチェーン照合 5 項目**（v2 params 一致・registry v2 active/旧 false・active=Aave・Etherscan==`8c05530`） | ⏳ **未検証**（public RPC 全滅でローカル不可） | 実 RPC で `cast` 実行（v2レポート §5 にコマンド） |
| 2 | 実 ETH RPC で `ERC4626AdapterEthMigrationForkTest` を green 実行 | ⏳ 未実行（RPC なし） | `$ETH_RPC_URL` 設定後 |
| 3 | 活性化直前に Morpho 供給 cap headroom ≥ `vault.totalAssets()` を再確認 | ⏳ 未確認 | 活性化トランザクション直前 |
| 4 | （将来 migrate-out 時のみ）migrate-out script に `require(isFullyExited())` | 📌 ランブック記載 | 該当スクリプト作成時 |

> 業務側（スコープ外）：TVL ≥ $50M（現 $38.1M）・スプレッド ≥ +0.8%（現 +52bps）は業務判断。

---

## 5. ✅ メインスレッド確認チェックリスト

メインスレッドは以下を確認のうえ、活性化の可否を判断してください：

- [ ] **判定を承認**：v1/v2 とも「条件付き GO」、Critical/High ゼロ、資金喪失不能を理解した
- [ ] **L-1 クローズを承認**：`rescue()` の二重コア除外＋再入耐性で問題なしと認める
- [ ] **V2-M1 を受容**：`isFullyExited()` 未強制は本活性化に無影響、将来 migrate-out は手続き強制でカバーする方針を承認
- [ ] **ブロッカー 1〜3 の完了を活性化の前提条件とする**ことに同意
- [ ] **現状維持を確認**：active=Aave のまま・資金未移動で問題ない

> 上記すべて ✅ なら、ブロッカー 1〜3 を満たした時点で **`ActivateERC4626Adapter.s.sol` による活性化を GO** と判断できます。
> いずれか保留があれば、その項目を本スレッドに差し戻してください。

---

## 6. 補足（ツール）
- Slither/Aderyn/Mythril は当環境未導入（ユーザー方針によりサイレント install 回避）。**活性化前に CI で Slither 回帰実行を推奨**。
- 本監査は手動コードリーディング + Foundry PoC（55 非fork green）を主力に実施。
