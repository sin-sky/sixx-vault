# sixx-vault — セットアップ手順

## 前提条件

- Foundry v1.7.1+ インストール済み (`foundryup` で最新に更新)
- `~/sixx-vault` に `forge init` 済み

---

## 1. この sixx-vault ディレクトリを ~/sixx-vault にコピー

```bash
# SIXXソースコードフォルダから ~/sixx-vault へ
cp -r ~/SIXXソースコード/sixx-vault/src       ~/sixx-vault/
cp -r ~/SIXXソースコード/sixx-vault/test      ~/sixx-vault/
cp    ~/SIXXソースコード/sixx-vault/foundry.toml  ~/sixx-vault/
cp    ~/SIXXソースコード/sixx-vault/remappings.txt ~/sixx-vault/
```

---

## 2. 依存ライブラリのインストール

```bash
cd ~/sixx-vault
export PATH="$HOME/.foundry/bin:$PATH"

forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install foundry-rs/forge-std --no-commit
```

---

## 3. ビルド確認

```bash
forge build
```

✅ 成功すると `Compiler run successful!` が表示される。

---

## 4. ユニットテスト（fork 不要）

```bash
forge test --match-contract SIXXVaultTest -vvv
```

---

## 5. Arbitrum fork テスト

```bash
# .env ファイルに追記
echo "ARB_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY" >> ~/.env
source ~/.env

forge test --fork-url $ARB_RPC_URL --match-contract AaveV3AdapterForkTest -vvv
```

### 再現性のある実行（ブロック番号固定）

```bash
forge test --fork-url $ARB_RPC_URL --fork-block-number 300000000 \
  --match-contract AaveV3AdapterForkTest -vvv
```

---

## 6. ファイル構成

```
src/
  interfaces/
    IStrategyAdapter.sol    # adapter 標準インターフェース
    ISIXXVault.sol          # vault 拡張インターフェース（ERC-4626 継承）
    IAdapterRegistry.sol    # registry インターフェース
    IAavePool.sol           # Aave V3 最小インターフェース
  core/
    SIXXVault.sol           # メイン Vault（ERC-4626 拡張）
    AdapterRegistry.sol     # adapter ホワイトリスト
  adapters/
    AaveV3USDCAdapter.sol   # Aave V3 USDC 利回り adapter

test/
  mocks/
    MockAdapter.sol         # ユニットテスト用モック
  SIXXVault.t.sol          # ユニットテスト（fork 不要）
  AaveV3Adapter.t.sol      # fork テスト（Arbitrum One）
```

---

## 7. デプロイパラメータ（Arbitrum One）

| 変数 | 値 |
|---|---|
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Aave V3 Pool | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` |
| aUSDC | `0x625E7708f30cA75bfd92586e17077590C60eb4cD` |

---

## 8. 次のステップ

- [ ] fork テスト通過確認
- [ ] Arbitrum Sepolia デプロイ（`script/Deploy.s.sol` 作成）
- [ ] AaveV3WBTCAdapter 実装（DESIGN_BACKEND_LEGO.md §6）
- [ ] LidoAdapter 実装（ETH Mainnet、DESIGN_BACKEND_LEGO.md §7）
- [ ] Slither 静的解析
- [ ] Trail of Bits / Code4rena 監査依頼
