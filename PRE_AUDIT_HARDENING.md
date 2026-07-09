# 監査前ハードニング記録（Slither triage → アーキ検証 → 実装）

**2026-07-02。** 外部監査に出す前の自前ハードニング。Slither 静的解析→triage→アーキテクト独立検証→実装＋forge テストの記録。監査会社への添付資料。

対象（自前 Solidity・約1,040行）: `src/core/SIXXVault.sol` / `src/core/AdapterRegistry.sol` / `src/adapters/AaveV3USDCAdapter.sol` / `src/adapters/VenusUSDTAdapter.sol`。既に監査1回済み（コードに `H-1〜H-4`/`M-1` マーカー）。governance=各チェーン 2-of-3 Safe。

## 実装した修正（このバッチ）

| ID | 内容 | 変更 |
|---|---|---|
| **A** | 緊急停止が「旧 adapter の recall 失敗」で brickしないよう `setEmergencyShutdown` の recall を **try/catch** 化（フラグ先行・失敗時 `AdapterRecallFailed` emit・activeAdapter 不変で資産は計上維持） | `SIXXVault.sol` |
| **B** | **緊急停止時はロック免除**（`maxWithdraw`/`maxRedeem`/`_withdraw` で `!emergencyShutdown` ガード）。「安全に出金できるよう」の意図を実装で担保（SHIN 確定=選択1） | `SIXXVault.sol` |
| **C** | Aave フル drain（`assets>=aToken.balanceOf`）を `type(uint256).max` に→ 差替/停止後の aUSDC dust 恒久ストランド解消（Venus は既存 drain-all で対応済） | `AaveV3USDCAdapter.sol` |
| **M13-16** | `_recallFromAdapter` に**受領差分アサーション**（`balanceOf` 前後差分 `>= toWithdraw` を require＝黙って少なく返す adapter を明示 revert） | `SIXXVault.sol` |
| **Low** | `setAdapter`/`setEmergencyShutdown` ＋ 両 adapter の `deposit`/`withdraw` に **nonReentrant**（深層防御） | `SIXXVault.sol`/両 adapter |

※ **setAdapter は直接呼びのまま**（recall 失敗時は revert が正＝資産 stranding を防ぐ。破損 adapter からの脱出は緊急停止が担う）。アーキ検証で合意。

## 検証
- **forge 非フォークテスト = 92 pass**（旧記録 61 から増。Timelock/guardian・Venus unit・rescue 等の追加分込み。faulty mock=`test/mocks/FaultyAdapter.sol`）。
- **Ethereum Aave フォークテスト = 6 pass**（`test_emergency_shutdown_full_flow` 含む＝C のフル drain を実 Aave 状態で検証）。
- **✅ 全フォーク実走完了（2026-07-09・forge 1.7.1）**: Alchemy 実 RPC で3 suite すべて green＝**Arbitrum Aave フォーク 6 pass**（APY 実測 248bps）／**BNB Venus フォーク 7 pass**（round-trip・emergency shutdown・full-exit-not-trapped・yield accrual・APY 35bps）／**Ethereum Aave フォーク 6 pass**。
  - ※過去「未実行」だった真因＝Alchemy App でネットワーク未有効化（403「network not enabled」）。キー無効ではなく、dashboard で ARB_MAINNET / BNB_MAINNET を有効化して解消。→ **監査/デプロイ前フォークブロッカーは全消化**。

## Slither triage（最終・lib/test 除外）
最終カウント: **High 3 / Medium 16 / Low 18 / Info 1 / Opt 3**。判定:

- **High ×3（全て `reentrancy-balance`・確定 FP）**: `SIXXVault._recallFromAdapter`（M13-16 の受領差分計測）と `VenusUSDTAdapter.withdraw`（drain-all の受領計測）。いずれも **(1) 全経路が nonReentrant 配下**（vault 公開入口＋governance 関数＋adapter に nonReentrant 付与済）、**(2) 外部先は Aave/Venus と標準 USDC/USDT（コールバック無し）＝攻撃者コードに制御が渡らない**、**(3) balanceOf 差分は受領額を正しく測る防御的計測**。read-only reentrancy も成立せず（攻撃者 external call が無い）。※slither の reentrancy-balance は nonReentrant 修飾子を考慮しないため残るが実リスク無し。アーキテクト独立検証で FP 確定。
- **Medium 16**: `incorrect-equality`（Venus の `require(redeem()==0)`＝成功コード規約／enum 比較／ゼロガード＝FP）・`uninitialized-local`（uint 0 初期化カウンタ＝FP）・`reentrancy-no-eth`(setAdapter＝onlyGovernance+nonReentrant)・`divide-before-multiply`/`incorrect-equality` @ collectFees（**M-1** の意図的希薄化式）・`unused-return`（受領は balanceOf 差分で検証するため adapter 戻り値は意図的に不使用）。**全て FP or 意図的**。
- **据置＋監査に文脈提示**: `performanceFee` は settable だが未使用（CLAUDE.md 明記の dead code・意図明示 or 削除は監査判断）。非標準/fee-on-transfer トークン非対応（実装制約＝標準・非 rebasing・fee-off のみ）。ERC4626 first-depositor は `_decimalsOffset()=9` で緩和済。

## 次
- ~~Arb/BNB フォークテストを有効 RPC で実行（デプロイ前）。~~ ✅ **完了（2026-07-09・上記「検証」参照＝3 suite 全 green）**。
- 外部監査に本書＋Slither JSON＋前回監査の H-*/M-* を添付。
- 監査 → 修正 → 再監査 → mainnet 再デプロイ（Venus dust 修正 `e8ed86a` と本バッチをまとめて・Safe 2-of-3 の `setAdapter` 移行）。
