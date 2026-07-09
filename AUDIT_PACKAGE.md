# SIXX Vault — 外部監査パッケージ（ベンダー向け入口）

> 2026-07-09 作成。外部監査ベンダーが**最初に読む索引**。詳細な自前ハードニング記録は `PRE_AUDIT_HARDENING.md`、コード規約は `CLAUDE.md` を参照。
> **凍結コミット（監査対象）**: `3d55dc5`（branch `main`）。以降の変更は監査ベンダーと合意の上で。

---

## 1. 監査スコープ

**対象＝USD 系4コントラクト＋その interface**（自前 Solidity）。solc **0.8.28**。

| ファイル | 行数 | 役割 |
|---|---|---|
| `src/core/SIXXVault.sol` | 454 | ERC-4626 vault。単一 adapter へ資金をルーティング |
| `src/core/AdapterRegistry.sol` | 122 | ガバナンス whitelist |
| `src/adapters/AaveV3USDCAdapter.sol` | 277 | Aave V3 USDC アダプター |
| `src/adapters/VenusUSDTAdapter.sol` | 288 | Venus USDT アダプター（BNB） |
| `src/interfaces/*.sol` | 330 | `IStrategyAdapter`/`ISIXXVault`/`IAdapterRegistry`/`IAavePool`/`IVenusVToken` |
| **計** | **1,471** | |

**スコープ外（本ラウンド非対象）**：
- `ERC4626Adapter`（汎用・Morpho/Sky/Ethena 再利用）は**別 feature ブランチ `feat/erc4626-morpho-adapter`**。v2 hardened が ETH mainnet に deploy 済（`0x83E6b5E4F3913F17aeE4eE99aa0711050af08a8D`・active=Aave 据置）でローカル監査🟢条件付き GO 済。**本ラウンドは USD 系4コア単独で先行**（相乗り可否は別途判断）。
- `lib/`（OpenZeppelin v5・forge-std）は監査対象外（上流）。

**Foundry プロファイル**：optimizer on（200 runs）・`via_ir = false`・fuzz `runs = 1000`・invariant `runs = 256` / `depth = 15`。

---

## 2. アーキテクチャ（3コントラクト）

単一の ERC-4626 **Vault** が、ガバナンス制御の **AdapterRegistry** で whitelist された **Adapter** を1つずつ経由して資金を運用。1 vault = 1 原資産（USDC 用に1つ）。

- **SIXXVault**：通常運用中 idle を持たず、`_deposit` は全額を active adapter へ push、`_withdraw` は必要分のみ recall。`totalAssets() = asset.balanceOf(vault) + adapter.totalAssets()`。
- **AdapterRegistry**：`setAdapter` は `registry.isActive(newAdapter)` を強制（`address(0)` は明示的 "pause" パスで check 迂回）。
- **IStrategyAdapter**：vault が原資産を adapter へ転送**してから** `deposit(amount)` を呼ぶ（PUSH 方式）。`withdraw(amount, recipient)` は recipient へ直送。auto-compounding adapter は `harvest()` no-op。書込入口は `onlyVault`。

---

## 3. 保存すべき不変条件（前回監査由来・コードに H-*/M-* マーカー）

- **H-1**：`setAdapter` は `newAdapter==address(0)` を除き registry whitelist を強制。
- **H-2**：ロック中の share transfer（`_update`）は revert。mint/burn は免除。
- **H-3**：deposit が `_lockedUntil[receiver]` を延長するのは `caller==receiver` の時のみ。
- **H-4**：ロック中は `maxWithdraw`/`maxRedeem` が 0 を返す。
- **M-1**：`collectFees` は希薄化式 `feeShares = feeAssets * supply / (assets - feeAssets)`（`previewDeposit` に戻さない）。
- 他：ハード fee cap（`MAX_PERFORMANCE_FEE=3000`=30%／`MAX_MANAGEMENT_FEE=500`=5%）、2-step governance、emergency shutdown、`_decimalsOffset()=9`（first-depositor inflation 緩和）。

**2026-07-02 の監査前ハードニング（本バッチ）**＝A/B/C/M13-16/nonReentrant（詳細 `PRE_AUDIT_HARDENING.md`）。
**C-1 ガバナンス・ハードニング**＝TimelockController(48h)＋guardian(各チェーン 2-of-3 Safe)、setEmergencyShutdown 非対称化（ON=guardian 即時/OFF=Timelock）。

---

## 4. テスト状況（凍結コミット `3d55dc5`・forge 1.7.1・2026-07-09 実走）

| suite | 結果 |
|---|---|
| 非フォーク全体 | ✅ **92 pass** / 0 fail |
| Ethereum Aave フォーク（`AaveV3AdapterEthForkTest`・`$ETH_RPC_URL`） | ✅ **6 pass** |
| Arbitrum Aave フォーク（`AaveV3AdapterForkTest`・`$ARB_RPC_URL`） | ✅ **6 pass**（APY 実測 248bps） |
| BNB Venus フォーク（`VenusUSDTAdapterForkTest`・`$BNB_RPC_URL`） | ✅ **7 pass**（round-trip・emergency shutdown・full-exit-not-trapped・yield accrual・APY 35bps） |

**フォーク実行コマンド**（要 Alchemy 等の実 RPC・対象ネットワーク有効化）：
```bash
forge test                                                                    # 非フォーク 92
forge test --fork-url $ETH_RPC_URL --match-contract AaveV3AdapterEthForkTest   # ETH Aave 6
forge test --fork-url $ARB_RPC_URL --match-contract AaveV3AdapterForkTest      # ARB Aave 6
forge test --fork-url $BNB_RPC_URL --match-contract VenusUSDTAdapterForkTest   # BNB Venus 7
```

---

## 5. 既知の意図的事項・実装制約（ベンダーへの文脈提示）

- **`performanceFee` は settable だが未使用**（accrual パス未参照＝現状 management fee のみ）。dead code として意図明示 or 削除は監査判断。
- **非標準/fee-on-transfer トークン非対応**（標準・非 rebasing・fee-off の USDC/USDT のみ）。
- **first-depositor inflation** は `_decimalsOffset()=9`（OZ v5 virtual-shares）で緩和済（USDC で 15-decimal shares）。
- **`setAdapter` は直接呼び**（recall 失敗時は revert が正＝資産 stranding 防止。破損 adapter からの脱出は emergency shutdown が担う）。
- **reentrancy-balance（Slither High×3）は確定 FP**：全経路 nonReentrant 配下＋外部先は Aave/Venus/標準 USDC/USDT（コールバック無し）＝攻撃者コードに制御が渡らない。詳細 `PRE_AUDIT_HARDENING.md §Slither triage`。

---

## 6. 静的解析（Slither）

- **triage 済**（最終カウント High 3 / Medium 16 / Low 18 / Info 1 / Opt 3＝全て FP or 意図的。判定は `PRE_AUDIT_HARDENING.md §Slither triage` に逐条）。
- ⚠️ **Slither JSON の再生成は open**：現作業環境（Codespace）に slither/solc 未導入のため本コミットでの JSON 添付は未生成。**監査提出前に slither-equipped 環境で `slither . --json slither.json` を再実行し添付**すること（triage 結論は前回から不変の見込みだが、凍結コミット `3d55dc5` に対する再走で確定）。

---

## 7. デプロイ状況（参考）

- **Arbitrum Sepolia（testnet）**：AdapterRegistry `0x4ca6dc159982134365547331a064514fe7085f35` / SIXXVault `0x289712ce63ad84cfe5721d2036a4693704382898` / AaveV3USDCAdapter `0x0fb1442f7c48f7256205050f1fa4a56e58b13bf9`。
- **本番 mainnet 再デプロイ**は監査 → 修正 → 再監査 の後（Venus dust 修正 `e8ed86a` と本バッチをまとめて・Safe 2-of-3 の `setAdapter` 移行）。

---

## 8. 提出チェックリスト（提出前に埋める）

- [x] 凍結コミット確定（`3d55dc5`）
- [x] スコープ確定（USD 系4コア＋interface・ERC4626Adapter は別ラウンド）
- [x] 全フォーク green（ETH/ARB Aave・BNB Venus）＋非フォーク 92 pass
- [x] 監査前ハードニング記録（`PRE_AUDIT_HARDENING.md`）
- [ ] **Slither JSON 再生成（要 slither 環境・凍結コミットに対して）**
- [ ] 前回監査レポート（H-*/M-* 原本）の同梱
- [ ] **監査ベンダー選定・見積・提出可否（要 SHIN＝コスト/対外）**
