# TEST RESULTS — `ERC4626Adapter` (Morpho / Gauntlet USDC Prime)

> 他スレッドからの参照用テスト記録。監査本体は
> [`AUDIT_REPORT_erc4626_adapter_2026-06-02.md`](./AUDIT_REPORT_erc4626_adapter_2026-06-02.md) を参照。

| | |
|---|---|
| 対象リポジトリ | `sin-sky/sixx-vault` @ `feat/erc4626-morpho-adapter` |
| ハードニング commit | `8c05530`（audit 反映：L-1 rescue + M-G1 isFullyExited + 回帰6本） |
| 監査コミット | `828ecfe`（ハードニング前） |
| 環境 | forge 1.7.1 / Solc 0.8.28 / OpenZeppelin v5.6.1 |
| ビルド | ✅ `forge build` 成功（lint 警告のみ・機能影響なし） |
| 実行日 | 2026-06-03 |

---

## 0. 結果サマリ

| 区分 | スイート | テスト数 | 結果 |
|---|---|---|---|
| Unit | `ERC4626AdapterUnitTest` | 21 | ✅ all PASS |
| Invariant | `ERC4626AdapterInvariantTest` | 1（256 runs / 3,840 calls） | ✅ **0 revert** |
| **Regression（ハードニングで新規）** | `ERC4626AdapterRegressionTest` | 6 | ✅ all PASS |
| Integration | `SIXXVaultTest` | 20 | ✅ all PASS |
| **合計（非 fork）** | | **48** | ✅ **48 / 48 PASS・0 fail** |
| Fork（RPC 必須） | 4 contract | — | ⏸ **未実行**（`.env` RPC 無し・活性化前に実走要） |

実行コマンド（非 fork）：
```bash
forge test --no-match-contract "Fork"
# => 48 passed, 0 failed, 0 skipped
```

---

## 1. Unit テスト（21本）`test/ERC4626Adapter.t.sol`

mock ERC-4626 に対する純ユニット。テスト contract 自身が sixxVault 役で PUSH モデルを直接行使。

| カテゴリ | テスト | 検証内容 |
|---|---|---|
| Constructor | `test_constructor_setsState` | state・無限 approve 設定 |
| | `test_constructor_revertsOnAssetMismatch` | `vault.asset()==asset` ガード |
| | `test_constructor_revertsOnZeroAddrs` | 全 zero-addr revert |
| deposit | `test_deposit_pushModel` | PUSH 預入・share 取得・totalAssets ≈ 預入額 |
| | `test_deposit_onlyVault` | 非 vault は revert |
| | `test_deposit_zeroAmountReverts` | 0 額 revert |
| | `test_deposit_whenPausedReverts` | pause 時 revert |
| withdraw | `test_withdraw_roundTrip` | 全額往復・recipient 着金・adapter drain |
| | `test_withdraw_capsAtMaxWithdraw` | **maxWithdraw クランプ**（過大要求でも上限まで） |
| | `test_withdraw_onlyVault` | 非 vault は revert |
| | `test_withdraw_zeroAmountReverts` | 0 額 revert |
| | `test_withdraw_zeroRecipientReverts` | zero recipient revert |
| | `test_withdraw_isNotPausedGated` | **pause 中も引出可**（ユーザー退出保証） |
| totalAssets | `test_totalAssets_tracksYield` | yield に追従 |
| | `test_totalAssets_neverOverstatesWithdrawable` | **floor で過大評価しない** |
| harvest/meta | `test_harvest_isNoOp` | no-op（0 返却） |
| | `test_metadata` | adapterType / riskLevel / APY / lockPeriod / providerName |
| Circuit breaker | `test_pause_auth` | pause は gov/vault のみ |
| | `test_unpause_onlyGovernance` | unpause は gov のみ |
| M-4 2-step | `test_twoStepGovernance` | 提案→承認・pending クリア |
| | `test_twoStepSixxVault` | 同上＋旧 caller 失効 |

---

## 2. Invariant テスト（1本・256 runs）`test/ERC4626Adapter.t.sol`

| テスト | 不変条件 | 結果 |
|---|---|---|
| `invariant_totalAssetsNotOverWithdrawable` | ランダムな deposit/withdraw/yield 列で常に `totalAssets() ≤ maxWithdraw` | ✅ 3,840 calls・**0 revert** |

handler 呼び出し内訳（一例）：accrueYield 1,297 / deposit 1,265 / withdraw 1,278。

---

## 3. ⭐ Regression テスト（6本・ハードニングで新規）`test/ERC4626AdapterRegression.t.sol`

監査 §4 攻撃シナリオ＋追加関数（rescue / isFullyExited）を恒久ロック。
mock：`CappedERC4626`（供給 cap）/ `IlliquidERC4626`（即時流動性上限）を同ファイル内に定義。

| テスト | シナリオ | 検証結果 |
|---|---|---|
| `test_reg_fakeVault_rejected` | §4-1 偽 sixxVault の deposit/withdraw | ✅ `ADAPTER: only vault` revert |
| `test_reg_donation_doesNotDistortAccounting` | §4-3 Morpho へ 100万 USDC donation で価格吊り上げ | ✅ floor で過大評価せず・`totalAssets ≤ maxWithdraw`・会計歪まず |
| `test_reg_withdrawClamp_noDriftProfit` | §4-4 部分流動性（10k）で withdraw クランプ | ✅ 過大要求(20k)は revert・過小引渡しなし・**share 価格 drift 利得不能** |
| `test_reg_migrateIntoCappedVault_fundsSafeIdle` | §4-6 / L-3 cap 満杯 vault への移行 | ✅ **5万 USDC が vault に idle 安全退避・喪失ゼロ・alice 全額退出可**（M-3 rollback） |
| `test_reg_rescue_protectsCore_recoversForeign` | L-1 rescue | ✅ asset/share は `core protected` で弾く・非gov は `not governance`・zero-to revert・foreign token 全量回収・**元本不変** |
| `test_reg_isFullyExited_tracksExit` | M-G1 isFullyExited | ✅ 空=true / 保有=false / emergency 全 recall 後=true |

---

## 4. Integration テスト（20本）`test/SIXXVault.t.sol`

vault×adapter 統合。既存監査の H-1〜H-4 / M-1 / M-3 不変条件を含む（`MockUSDC` + `MockAdapter`、fork 不要）。

| テスト | 検証内容 |
|---|---|
| `test_deposit_mints_shares` / `test_withdraw_returns_assets` | 基本預入・引出 |
| `test_preview_deposit_matches_actual` | preview 整合 |
| `test_multiple_depositors` | 複数 depositor の share 配分 |
| `test_set_adapter_migrates_assets` | adapter 切替で資産移行 |
| `test_setAdapter_rejectsUnregisteredAdapter` | **H-1**：registry 未登録 adapter 拒否 |
| `test_deposit_survivesAdapterRevert` | **M-3**：adapter revert でもユーザー deposit 成功（資金 idle 退避） |
| `test_lockBypassViaTransfer` | **H-2**：ロック中の share 転送遮断 |
| `test_lockGriefingByAttacker` | **H-3**：第三者預入で被害者ロック延長されない |
| `test_maxWithdraw_returnsZeroWhenLocked` | **H-4**：ロック中 maxWithdraw=0 |
| `test_lock_period_blocks_early_withdraw` / `_allows_withdraw_after_expiry` | ロック期間挙動 |
| `test_emergency_shutdown_blocks_deposits` / `_recalls_assets` / `_allows_withdrawal` | emergency shutdown |
| `test_max_deposit_zero_on_shutdown` | shutdown 中 maxDeposit=0 |
| `test_management_fee_mints_shares` / `test_collectFees_dilutionMath` | **M-1**：fee dilution 計算 |
| `test_governance_transfer_two_step` / `test_non_pending_cannot_accept_governance` | 2-step governance |

---

## 5. Fork テスト（未実行・RPC 必須）

ローカルに `.env`（RPC）が無いため **スキップ／未実行**。活性化前に実走が必要。

| contract | 対象 | 実行コマンド | 用途 |
|---|---|---|---|
| `ERC4626AdapterBaseForkTest` | Gauntlet USDC Prime (Base) 実 vault 往復 | `forge test --fork-url $BASE_RPC_URL --match-contract ERC4626AdapterBaseForkTest` | 実 vault 健全性 |
| `ERC4626AdapterEthForkTest` | Steakhouse USDT (ETH) 実 vault 往復 | `forge test --fork-url $ETH_RPC_URL --match-contract ERC4626AdapterEthForkTest` | 汎用性確認 |
| **`ERC4626AdapterEthMigrationForkTest`** | **本番 vault で Aave→Morpho 移行全フロー**（5万 seed・移行・往復） | `forge test --fork-url $ETH_RPC_URL --match-contract ERC4626AdapterEthMigrationForkTest` | **活性化前 必須ブロッカー①** |
| `AaveV3AdapterForkTest` | 既存 Aave（Arbitrum） | `forge test --fork-url $ARB_RPC_URL --match-contract AaveV3AdapterForkTest` | 既存 adapter 回帰 |

> 注：全スイート（fork 含む）を RPC 無しで回すと `AaveV3AdapterForkTest` のみ setUp で fail（`SafeERC20FailedOperation` — 実 USDC 不在）。これは**既存 fork テストの想定挙動**で、本ハードニングの変更とは無関係。非 fork 限定では 0 fail。

---

## 6. 再現手順

```bash
cd ~/sixx-vault-audit
git checkout feat/erc4626-morpho-adapter          # commit 8c05530
git submodule update --init --recursive           # OZ v5.6.1 / forge-std
forge build                                        # 成功（警告のみ）

# 非 fork（48 本）
forge test --no-match-contract "Fork"

# 個別スイート
forge test --match-contract ERC4626AdapterUnitTest -vvv
forge test --match-contract ERC4626AdapterRegressionTest -vvv
forge test --match-contract ERC4626AdapterInvariantTest -vvv
forge test --match-contract SIXXVaultTest -vvv

# fork（RPC 設定後・活性化前ブロッカー）
forge test --fork-url $ETH_RPC_URL --match-contract ERC4626AdapterEthMigrationForkTest -vvv
```

---

## 7. 結論

- **非 fork 48 / 48 が green**、invariant 256 runs / 0 revert。ビルド成功。
- ハードニングで **回帰 6 本を追加** — 監査で実証した攻撃耐性（偽vault / donation / clamp drift / cap 移行）と新関数（rescue / isFullyExited）を CI で恒久的に保護。
- 残課題は **fork テストの実 RPC 実走**（活性化前ブロッカー①）。`$ETH_RPC_URL` 設定後に実行。
