# SIXX Vault — 監査スコープ（SCOPE）

> 外部監査／専門レビュー用。**凍結コミット `0703525`**（`main`・Round 5＝第2独立レビュー H-01／M-01／L-01／P-02／P-03 remediation 反映済）。solc 0.8.28。
> （履歴：Round 2 `b939dd2` → Round 3 `173e3fb`（Part B P1-P4）→ Round 4 `78aa8c1`（独立 Handoff 監査 M-01〜M-05／L-01）→ 本 Round 5 `0703525`（第2独立レビュー：H-01 unread-detach deposit-pause／M-01 Pendle swapper 無期限 allowance 廃止／L-01 Ethena deploy broadcast-guard／P-02 aderyn ゲート機械判定／P-03 invariant・Echidna 追加）。詳細＝`SIXX_Vault_Handoff_Audit_Report.md`／`THREAT_COUNCIL_REMAINING_2026-07-11.md`／`REMEDIATION_PROPOSALS.md`。）
> 補完文書：入口＝`audit/README_FOR_REVIEWER.md`／既知FP＝`audit/SLITHER_TRIAGE.md`＋`audit/ADERYN_TRIAGE.md`＋`AUDIT_PACKAGE.md §Slither`／等価変異＝`audit/MUTATION_TRIAGE.md`／自前ハードニング＝`PRE_AUDIT_HARDENING.md`。

---

## 1. In-Scope（自前 Solidity＝監査対象）

実測 LoC（`0703525`・`wc -l`）。**合計 3,024 行 / 16 ファイル**（Round 4 比 +34：SIXXVault +15・PendlePTAdapter +14・ISIXXVault +5＝第2独立レビュー H-01/M-01 remediation）。

### 1.1 コア（会計・ガバナンス）
| ファイル | LoC | 役割 |
|---|---:|---|
| `src/core/SIXXVault.sol` | 621 | ERC-4626 vault。単一 adapter へ資金ルーティング。share/asset 会計・lock・fee・emergency shutdown・2-step governance・deposit-pause(M-03/H-01：unread-detach も pause＋max\* 反映) |
| `src/core/AdapterRegistry.sol` | 122 | ガバナンス whitelist（`isActive`/`registerAdapter`） |

### 1.2 アダプター（各外部プロトコル連携）
| ファイル | LoC | 連携先（外部＝out-of-scope 本体） |
|---|---:|---|
| `src/adapters/AaveV3USDCAdapter.sol` | 277 | Aave V3 Pool（USDC・Arbitrum） |
| `src/adapters/VenusUSDTAdapter.sol` | 288 | Venus vToken（USDT・BNB） |
| `src/adapters/EthenaSUSDeAdapter.sol` | 431 | Ethena `StakedUSDeV2` ＋ Curve StableSwap-NG（USDC↔USDe↔sUSDe↔crvUSD） |
| `src/adapters/PendlePTAdapter.sol` | 604 | Pendle Router V4 ＋ 注入 `IStableSwapper`（USDC↔USDe / sUSDe→USDC）。deposit/withdraw は実残高デルタ検算（M-04/M-05）。swapper は swap 毎 exact-approve→0（M-01：無期限 allowance 廃止） |

### 1.3 インターフェース（自前宣言）
| 区分 | ファイル（LoC） |
|---|---|
| 自前コントラクトの IF | `IStrategyAdapter`(80) / `ISIXXVault`(143) / `IAdapterRegistry`(49) |
| 外部 ABI の自前ヘッダ | `IAavePool`(54) / `IVenusVToken`(47) / `IPendleRouter`(140) / `IPendleCore`(70) / `IStakedUSDeV2`(29) / `ICurveStableSwapNG`(23) / `IStableSwapper`(27) |

> 外部 ABI ヘッダ自体は自前コード＝**宣言の正しさ（selector/戻り値型/デコード）は in-scope**。指す先の実装は out-of-scope（§2）。

> **`script/`（Deploy/wiring）** はハンドオフ zip にビルド可能性と配線レビューのため同梱（`test/DeployWiring.t.sol` が依存）。公開アドレスのみ・秘密なし。会計コアの主対象ではないが**配線の正しさ（governance=Timelock / guardian=Safe / registry 強制）は要確認**。

---

## 2. Out-of-Scope（継承・外部＝監査対象外）

| 区分 | 対象 | バージョン/所在 | 理由 |
|---|---|---|---|
| ライブラリ | OpenZeppelin Contracts（`ERC4626`/`ERC20`/`IERC20`/`IERC4626`/`SafeERC20`/`ReentrancyGuard`/`TimelockController`） | **v5.6.1**（`lib/openzeppelin-contracts`） | 上流で監査済み。SIXX は継承利用のみ |
| ライブラリ | forge-std | **v1.16.1**（`lib/forge-std`） | テスト専用 |
| 外部プロトコル本体 | Aave V3 Pool / Venus vToken / Pendle Router V4・Market / Ethena `StakedUSDeV2` / Curve StableSwap-NG プール | 各オンチェーン deployed | 第三者運用の外部契約。SIXX は呼び出し側 |
| 外部集約/ルーティング | `IStableSwapper` 実装（0x / LI.FI 等のオフチェーン経路を裏に持ち得る swap 実行体） | governance が注入 | 実装は差し替え可能な外部部品（信頼前提は §3） |

---

## 3. 連携境界（Boundary＝In-Scope の重点）

外部本体は out-of-scope だが、**SIXX 側の呼び出し境界は in-scope**。監査で必ず見る点：

- **戻り値を信用しない会計**：adapter は外部 `deposit`/`withdraw` の戻り値を使わず、**実残高デルタ**で `received` を算定し `require(received >= toWithdraw)`（M13-16）。vault の `totalAssets()` も実残高ソース。
- **swap 境界**（Ethena=Curve・Pendle=Router＋swapper）：スリッページ上限・満期前後の価格評価（満期後は額面償還）・入出金経路の資産保全。
- **失敗の封じ込め**：M-3 の `__atomicPushToAdapter` 自己呼び出し（reverting adapter は safeTransfer ごと巻き戻り＝資金は idle 保持・ユーザー deposit は成功）。
- **非カストディ境界**：`withdraw(assets, recipient)` は recipient へ直送。プロダクト側ウォレットを経由する資金移動が無いこと。
- **DCA keeper（信頼前提）**：積立の毎月実行はオフチェーンの NestJS cron（`affliate-api`）。**オンチェーンの keeper コントラクトは本 repo に無い**。keeper は「ユーザーの ERC-20 approve 範囲で `deposit` を叩くだけ」の外部呼出者＝**資金を自身へ付け替える権限は持たない**（share は受益者に発行）。keeper 鍵の失効/濫用時の最悪影響が「approve 上限までの入金トリガ」に限定されることの確認が論点。

---

## 4. デプロイ状況（参考・監査対象コードそのものではない）

- **Arbitrum Sepolia（testnet）**：Registry `0x4ca6…5f35` / Vault `0x2897…2898` / Aave adapter `0x0fb1…3bf9`。
- ガバナンス＝TimelockController(48h)＋guardian(各チェーン 2-of-3 Safe)（C-1・`PRE_AUDIT_HARDENING.md`）。
- **本番 mainnet 再デプロイは監査→修正→再監査の後**（`docs/operations/contract-audit-checklist.md` の mainnet ゲート）。
