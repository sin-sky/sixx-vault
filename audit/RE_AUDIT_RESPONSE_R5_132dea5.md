# Re-Audit Response — "SIXX Vault Round 5 Re-Audit Report" (`132dea5`)

> 対象レポート: `SIXX_Vault_Handoff_Audit_Report_132dea5.md`（bundle `sixx-vault-audit-handoff-132dea5.zip`・凍結 src `0703525`）。
> 応答日: 2026-07-12。**結論：本レポートの全 finding は、レポートが対象とした bundle の直後に landing した Round 6（凍結 src `2e8f059`）で既に remediation 済み。**

---

## 要旨

外部監査人がレビューした bundle `132dea5` は **Round 5 スナップショット（src `0703525`）**で、
その **直後の Round 6（src `2e8f059`・tag `audit-freeze-ed1e1d6`）で H-02／M-02／M-03／L-02／L-03 ＋
Aderyn ゲートを全て修正**しています。レポートの各 finding を修正コミット・回帰テスト・コード位置に対応付けます。
全回帰テストは現行 tip で PASS（下記コマンドで再現可能）。

| Finding | Severity | 状態 | Round 6 修正（src `2e8f059`） | 回帰テスト（現行 PASS） |
|---|---|---|---|---|
| **H-02** shutdown 後 `totalAssets()` revert で退出不能 | High | ✅ 修正済 | `totalAssets()` を try/catch 化し read 失敗時 `_totalDebt` fallback（＝**revert しない**）／`_recallFromAdapter` の mark read を try/catch＋best-effort `needed` fallback／`_collectFees` 前段も安全化（SIXXVault L154-181, 358-365, 542-561） | `test_H02_redeem_succeeds_underShutdown_whenTotalAssetsReverts`（**実 assets 受領をアサート**）／`test_H02_recall_fallsBack_whenTotalAssetsReverts_noShutdown`／`test_chain_shutdown_fee_totalAssetsRevert_redeemDelivers` |
| **M-02** governance Timelock 永続性が非強制 | Medium | ✅ 修正済 | mainnet（chainid==1）で `proposeGovernance` が `code.length>0` ＋ `ITimelockMinDelay.getMinDelay()>=48h` を要求（SIXXVault＋AdapterRegistry） | `test_M02_vault_proposeGovernance_mainnet_{rejectsEOA,rejectsShortTimelock,acceptsTimelock48h}`／`_registry_…rejectsEOA` |
| **M-03** registry が adapter 実体配線を非検証 | Medium | ✅ 修正済 | `setAdapter` で `asset()==asset()`・`vault()==this`（hard）・`governance()==governance`（best-effort）を検証 | `test_M03_setAdapter_rejects{Asset,Vault,Governance}Mismatch`／`_acceptsCorrectlyBoundAdapter` |
| **L-02** Aave/Venus/Ethena rescueToken が underlying 非保護 | Low | ✅ 修正済 | 3 adapter の `rescueToken` に `require(token != asset, "ADAPTER: cannot rescue principal")` 追加（Pendle と同型） | `test_L02_rescue_cannot_take_underlying`（3 adapter） |
| **L-03** getActiveAdapters view DoS（`_adapterList` 無期限増加） | Low | ✅ 修正済 | `AdapterRegistry` に `MAX_ADAPTERS=100` cap（`registerAdapter`） | `test_L03_registerAdapter_enforcesMaxAdapters` |
| **Aderyn ゲート** exit≠0 が OVERALL clean PASS | ゲート | ✅ 修正済 | 既定で **crash(exit≠0/no-report/no-summary) → FAIL**（clean PASS 不能）。`ADERYN_ADVISORY=1` で WARN 降格＋summary が "**PASS WITH WARNINGS — manual review required**"。Slither を PRIMARY ゲート・Aderyn を副次に明記 | `scripts/contract-audit.sh` Stage 7／`audit/ADERYN_TRIAGE.md`（0.6.8 完走・Slither cross-check） |

---

## 各 finding 詳細

### H-02（本レポートの主要指摘）— 修正済

外部監査人の指摘した実行経路（1. shutdown → 3. redeem → 4. `_recallFromAdapter` の `totalAssets()` revert →
5. 退出不能）と、`_collectFees()` 前段の同一問題は、Round 6 で以下により解消：

1. **`totalAssets()` は revert しない**：adapter read を try/catch し、失敗時は最後に booked した `_totalDebt`
   に degrade。ERC-4626 の redeem/withdraw 換算・preview・`_collectFees` は全てこの `totalAssets()` を通るため、
   read 失敗が退出をブロックしなくなった。
2. **`_recallFromAdapter` の `available` 読取**（レポートが引用した `uint256 available = IStrategyAdapter(activeAdapter).totalAssets();`）を **try/catch＋best-effort `needed` fallback** 化。`received >= toWithdraw` guard は維持。
3. 監査人が「現行テストは flag と maxDeposit のみ」と指摘した点に対し、**shutdown → totalAssets revert 下で
   redeem が実際に assets を受領して成功する**回帰テストを追加（`test_H02_redeem_succeeds_underShutdown_whenTotalAssetsReverts`）。

**残る「完全凍結（totalAssets も withdraw も revert）」は force-detach 救済モデルに帰着**（write-off 後に
残余 pro-rata 退出）——これは仕様上のトレードオフとして明文化済み（`FUND_PROTECTION_UNDER_FAILURE.md`）。

### M-02 / M-03 / L-02 / L-03 — 修正済（上表の通り）

いずれも監査人の推奨対応そのもの（M-02＝mainnet gate で Timelock 強制／M-03＝登録・切替時に配線検証／
L-02＝underlying を Pendle 同様 rescue 対象外／L-03＝list 上限）を実装。M-02 は testnet の EOA governance を
壊さないため mainnet 限定強制、mainnet gate G1 目視確認と併用（`docs/operations/mainnet-gate.md`）。

### Aderyn ゲート — 修正済

監査人の指摘「exit 非ゼロ時は全体 FAIL、または manual review required」を実装：**既定 exit≠0 → FAIL**、
`ADERYN_ADVISORY=1` で WARN（MANUAL REVIEW 明示）＋ summary 全体表示を "PASS WITH WARNINGS" に。
exit=101（Aderyn 0.6.8 の環境依存 panic）対策として動く版ピン留め or advisory 降格の escape を提供。

---

## その後の追加検証（Round 6 以降・Part A）

H-02 の震源「状態遷移 × `totalAssets()`-revert」を系統的に総ざらい済み（全て新規違反ゼロ）：
- `STATE_TRANSITION_FUZZ_2026-07-12.md`：全ライフサイクル操作 × 障害注入の stateful fuzz（INV-1..9）。
- `MULTI_ADAPTER_FAULT_2026-07-12.md`：複数 adapter × 障害（MINV-1..6・アーキ判定＝単一 active）。
- `DECIMAL_PRECISION_BOUNDARY_2026-07-12.md`：桁跨ぎ換算・丸め（DINV-1..6・Halmos ∀証明付き）。

---

## 再現手順（現行 tip）

```bash
git checkout main   # src frozen at 2e8f059 (tag audit-freeze-ed1e1d6); 全 fix 反映
forge test --evm-version cancun --no-match-contract Fork   # 257 passed
forge test --match-test 'test_H02_redeem_succeeds_underShutdown_whenTotalAssetsReverts'  # H-02 実退出
./scripts/contract-audit.sh   # OVERALL PASS（aderyn crash は既定 FAIL）
```

## 判定

**本レポートの全 finding（H-02 含む）は Round 6 で解消済み。** 外部監査人には、`132dea5` ではなく
**現行の再凍結 bundle（src `2e8f059`／tag `audit-freeze-ed1e1d6` 以降）**での再監査を依頼するのが適切。
H-02 の「完全凍結時の force-detach 救済トレードオフ」は明文化済みで、監査人の確認を歓迎する。
