# sixx-vault

SIXX の非カストディ利回り Vault（Solidity・Foundry・非アップグレード）。

---

## 🔒 AUDIT FREEZE — `feat/vault-integrated`（2026-07-24）

**外部監査提出のため、下記コミットで 1-F コード凍結を実施しました。**

| 項目 | 値 |
|---|---|
| ブランチ | `feat/vault-integrated` |
| **凍結コミット** | **`af2b679`**（`af2b6791023a52b870f63f4152e43f3aedb8b0dc`） |
| 不変タグ | **`audit-freeze-v2-20260724`** ← 監査はこのタグ（=af2b679）で行う |
| 凍結日時 | 2026-07-24 16:23 JST |
| テスト | 非fort **361 passed / 0 failed**（fork は要 RPC） |
| Slither | High **9（全 FP・根拠付き）** / Med 60 / Low 76 / Info 60 |
| 内部監査 | custody / Solidity 正確性・セキュリティ ともに **Critical/High = 0** |

**⛔ 以後このコミット（`audit-freeze-v2-20260724` = af2b679）へのコード変更は禁止です。**
監査期間中の修正が必要になった場合は、**新ブランチ**を切って対応し、監査会社と合意の上で差分レビューとして扱います。凍結コミット自体は書き換えません。

- 提出パッケージ・Slither 全 High の FP 根拠：`sixx-workspace/threads/code_audit/PRE_AUDIT_HARDENING_v2.md`
- スコープ確定版：`sixx-workspace/threads/code_audit/EXTERNAL_AUDIT_SCOPE_v2_2026-07-22.md`
- 内部監査サマリ：`sixx-workspace/threads/code_audit/INTERNAL_AUDIT_SUMMARY_v2_2026-07-24.md`
- 凍結記録：`sixx-workspace/threads/code_audit/FREEZE_1F_2026-07-24.md`

---

## スコープ（v2・新規）

- コア: `SIXXVault`（ERC-4626・profit-lock ADR-007#2・**3-C depositCap**）／`AdapterRegistry`
- 運用アダプター: `LidoStETHAdapter`(ETH)・`BNBStakingAdapter`(BNB)・`ERC4626Adapter`(汎用・Morpho USDC Prime 等)
- 運用器: `BasketAllocator`（複数アダプターへ比率配分・H-1 白名单）
- 積立実行: `DCAScheduler`・`DCASpotAccumulator`・`ChainlinkDCAOracle`・`UniV3SpotSwapper`（keeper 実行のみ・非カストディ）

## ビルド / テスト

```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build
forge test --no-match-contract Fork          # 非fort 361 pass
# git 操作は env -u GITHUB_TOKEN git ...（GITHUB_TOKEN 未unset だと 403）
```
