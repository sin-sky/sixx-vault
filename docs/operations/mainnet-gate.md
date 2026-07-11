# Mainnet 反映ゲート — SIXX Vault（本番デプロイ前の必須チェック）

> 本番 mainnet への新規デプロイ / adapter 活性化 / governance 反映を行う前に、**全項目 PASS** を確認する。
> 監査対象コード自体ではなく**運用ゲート**。逸脱がある場合は本番反映を実行しない。
> 関連：`PRE_AUDIT_HARDENING.md`（C-1）・`audit/REMEDIATION_PROPOSALS.md`（P5）・`audit/THREAT_COUNCIL_2026-07-11.md`（運用規約）。

---

## G0. コード健全性

- [ ] `scripts/contract-audit.sh` 全ゲート PASS（build / test / coverage ≥85% / invariant / echidna / slither baseline 差分クリーン / aderyn）。
- [ ] デプロイ対象コミットが **再凍結タグ**（外部監査提出版）と一致（Etherscan 検証ソース照合）。
- [ ] fork suite（`--fork-url` 実 RPC）で対象 adapter が green。

## G1. ガバナンス・ハードニング（Part B P5・AC4 — **必須**）

- [ ] `governance` = **TimelockController(48h)**（単一 EOA 禁止）。deploy script は EOA gov で revert する設計（C-1）だが、**実アドレスが Timelock であることを明示確認**。
  - **M-02（第3レビュー・オンチェーン強制済）**：`SIXXVault`/`AdapterRegistry` の `proposeGovernance` は
    mainnet（`chainid==1`）で **`code.length>0` かつ `ITimelockMinDelay.getMinDelay() >= 48h`** を要求し、
    EOA / 48h 未満 Timelock を revert する。本チェックリストは初期 governance（constructor 配線）と
    ローテ先の**実体が正しい Timelock か**の目視確認を担う（オンチェーン強制はローテ経路をカバー）。
- [ ] `guardian` = 各チェーン **2-of-3 Gnosis Safe**（`setEmergencyShutdown` の即時 pause 権限）。
- [ ] `feeRecipient` = 承認済 treasury（EOA でないこと推奨）。
- [ ] **AdapterRegistry の `governance` も Timelock 配下**（`registerAdapter` / `setAdapterStatus` が自動的に 48h 遅延を受ける）。
  - 根拠：単一鍵漏洩時でも、悪意 adapter の登録→切替は Timelock 48h の検知窓を経る（AC10/AC4 の registry 信頼前提の緩和）。
- [ ] governance 2-step 移転（`proposeGovernance`→`acceptGovernance`）の受領先が正しいこと。event（`GovernanceProposed`/`GovernanceAccepted`）で追跡可能（Part B P2）。

## G2. adapter 活性化ゲート（該当時）

- [ ] `setAdapter` 先が registry で `isActive` = true（H-1 whitelist）。
- [ ] **連続 accrual アダプターのみ**（profit-streaming 着地までの運用 invariant・`THREAT_COUNCIL_2026-07-11` 運用規約 1）。報酬請求型（離散収穫）は登録禁止。
- [ ] 外部プロトコルの供給 cap / 流動性 headroom ≥ `vault.totalAssets()`。
- [ ] Pendle adapter は `twapDuration >= 900`（15分・Part B P3）かつ deploy 時 oracle readiness 済。

## G3. 退出/緊急経路の実機確認

- [ ] `setAdapter(address(0))`（force-detach）と `setEmergencyShutdown(true)` の権限保有者が正しい鍵（guardian/gov）であること。
- [ ] デペグ runbook（Ethena/Pendle exit 床 revert 時の手順）が運用手順書に存在。

## G4. Keeper / 非カストディ（DCA 該当時）

- [ ] DCA Keeper 鍵に **ユーザー資産 / sxUSDC の allowance を付与しない**（treasury 入金限定・permit 化まで）。HSM/KMS・per-cycle exact 承認。

---

> **本ゲートは実資金が動く不可逆操作の直前チェックリスト。1項目でも未達なら本番反映を保留し SHIN にエスカレーション。**
