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
  - **M-02（第3レビュー・オンチェーン強制済／F-1 で本番チェーン集合に拡張）**：`SIXXVault`/`AdapterRegistry`
    の `proposeGovernance` は**全本番チェーン**（`_isProductionChain()` = Ethereum `1`／Arbitrum One `42161`／
    BNB `56`）で **`code.length>0` かつ `ITimelockMinDelay.getMinDelay() >= 48h`** を要求し、
    EOA / 48h 未満 Timelock を revert する。
    - ⚠️ **F-1 修正前は `chainid==1` のみ**で、deploy が本番配線する Arbitrum One / BNB では強制が無効だった
      （生 EOA へ governance 移譲可能）。本 vault の主戦場は Arbitrum One。新チェーンを deploy 対象に追加する際は
      `Deploy.s.sol` の chain 集合と `SIXXVault._isProductionChain` / `AdapterRegistry._isProductionChain` の
      **3 箇所を同時更新**すること（不一致は本ゲートの盲点になる）。
    - 本チェックリストは初期 governance（constructor 配線）とローテ先の**実体が正しい Timelock か**の目視確認を担う。
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
- [ ] デペグ runbook（Ethena/Pendle exit 床 revert 時の手順）が運用手順書に存在
      → **`docs/operations/depeg-mark-staleness-runbook.md`**（ADR-007 残余の運用防御：検知シグナル A/B/C・
      WARN/ACT 閾値・force-detach 手順・30 分レイテンシ予算）。§5 のライブ監視実装と expedited detach 経路が未了なら本ゲート保留。
- [ ] **F-2（NAV × 可変 slippage 裁定の運用緩和・Ethena/haircut 連動 adapter 該当時）**：
  - [ ] 当該 vault の `lockPeriod` を **非ゼロに設定**（`setLockPeriod`）。`EthenaSUSDeAdapter.totalAssets()` は
    可変 `slippageBps` に連動するため、`slippageBps` を絞る（例 300→50）と NAV が単一 tx で最大 ~2.5% 跳ねる。
    `lockPeriod==0` だと「tighten 直前 deposit → 直後 redeem」で既存 holder から裁定抽出可能。非ゼロ lock（H-2/H-4）で
    round-trip を封鎖する（一般 JIT 防御も兼ねる）。詳細＝`audit/ADVERSARIAL_HARDENING_2026-07-12.md` F-2。
  - [ ] `setSlippageBps` 変更手順は **変更前後で deposit を pause**（adapter `pause()` か vault emergency）し、
    NAV 段差を跨ぐ新規入金/退出を止めてから実施する。

## G4. Keeper / 非カストディ（DCA 該当時）

- [ ] DCA Keeper 鍵に **ユーザー資産 / sxUSDC の allowance を付与しない**（treasury 入金限定・permit 化まで）。HSM/KMS・per-cycle exact 承認。

---

> **本ゲートは実資金が動く不可逆操作の直前チェックリスト。1項目でも未達なら本番反映を保留し SHIN にエスカレーション。**
