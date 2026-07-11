# Threat Council — SIXX Vault 残る脆弱性型 ②③④⑦⑧ 全面協議（2026-07-11）

> 3席の敵対的合議（席1 protocol-engineer=実装/攻撃者・席2 custody-auditor=資金境界・席3 orchestrator=横断/懐疑）。
> 対象：`PRE_AUDIT_SELF_REMEDIATION` の8型のうち **②アクセス制御・③丸め/share算/インフレ・④オラクル/価格・⑦DoS/stranding・⑧署名/リプレイ**。
> （①⑤⑥＝再入/liveness/fee は `THREAT_COUNCIL_2026-07-11.md`＋ADR-007 で合議・実装済。）
> 対象コミット：**凍結 `68eb3ec`**（コード凍結 `b939dd2`・以降は devcontainer/docs のみ）。solc 0.8.28。
> **Part A（本書）＝本番コード無改変。テスト/PoC/文書のみ。** 実バグの是正案は `REMEDIATION_PROPOSALS.md`（Part B・マージ禁止）。
> 関連：`SCOPE.md`・`README_FOR_REVIEWER.md`・`THREAT_COUNCIL_2026-07-11.md`・`MUTATION_TRIAGE.md`・`SLITHER_TRIAGE.md`。

---

## 結論（TL;DR）

- **新規の HIGH / MEDIUM 実バグは検出されず。** ②③④⑦⑧ の全ベクターは「安全確認済」か「既知の運用/将来スコープ」に落ちる。
- 実挙動として拾った **LOW/informational は3件**（いずれも資金喪失リスクなし）→ **✅ 2026-07-11 SHIN 承認で P1/P2/P3/P4 実装済**（`REMEDIATION_PROPOSALS.md`）：
  1. **RD5 → 【FIXED P1】**：zero-share になる極小 deposit を `require(shares>0)` で revert 化（旧＝OZ v5 標準で dust を取っていた・自己負担・非 insolvency）。
  2. **AC8-obs → 【FIXED P2】**：`setManagementFee`＋Registry gov 移転に event 追加（`setPerformanceFee` は P4 で無効化＝無音状態なし）。
  3. **OR2/⑤ 継続 → 【FIXED P3】**：Pendle `twapDuration >= 900`（15分）下限強制。
- carry-over `performanceFee` dead-code → **【FIXED P4】** not-implemented revert 化。本番 Timelock/Safe（P5）は **本番前運用ゲート据え置き**（`docs/operations/mainnet-gate.md`）。
- **新規 PoC は `test/ThreatCouncilRemaining.t.sol`（28本）＋`test/RemediationPartB.t.sol`（7本・P1-P4 挙動）。非フォーク全 189 本 green・`contract-audit.sh` 全ゲート PASS。**

---

## 新規 PoC（`test/ThreatCouncilRemaining.t.sol`・28本 all green）

| 型 | test | 主張 |
|---|---|---|
| ② | `test_AC_setAdapter/​setLockPeriod/​setPerformanceFee/​setManagementFee/​setFeeRecipient/​setGuardian/​proposeGovernance_unauthorizedReverts`（7本） | 全 `onlyGovernance` 関数が非認可で revert |
| ② | `test_AC_emergencyShutdown_activate_unauthorizedReverts` | 第三者は pause 不可 |
| ② | `test_AC_emergencyShutdown_guardianCannotUnpause` | guardian は pause 可・unpause 不可（AC9 権限分離） |
| ② | `test_AC_acceptGovernance_onlyPending` | 乗っ取り不可（pending 限定） |
| ② | `test_AC_registry_registerAdapter/​setAdapterStatus_unauthorizedReverts` | registry 変更は gov 限定 |
| ② | `test_AC_atomicPushToAdapter_selfOnly` | M-3 自己呼出境界（外部から資金誘導不可） |
| ② | `test_AC_twoStepGovernance_transfersPowerAtomically` | propose→accept で権限が原子的に移り、旧 gov は無力化（AC7） |
| ③ | `test_RD1_firstDepositorInflation_defended` | virtual shares(offset=9) で被害者非搾取・攻撃者非利益 |
| ③ | `test_RD3_dustCycles_noProfit_noInsolvency` | 200 往復 dust で利益ゼロ・非 insolvency |
| ③ | `test_RD4_directDonation_noInsolvency_noShareTheft` | 直接寄付は既存者に帰属・搾取不能 |
| ③ | `test_RD5_zeroShareDeposit_nowReverts` | zero-share 入金は `VAULT: zero shares` で revert（P1 実装後・資金移動なし） |
| P1-P4 | `test/RemediationPartB.t.sol`（7本） | Part B 実装挙動（zero-share revert・event 発火・Pendle twap>=900・performanceFee not-implemented） |
| ④ | `test_OR_adapterStrayDonation_doesNotInflateVaultNAV` | adapter へ直接送金しても NAV 不変（償還ベース＝spot 非依存） |
| ④ | `test_OR_inBlockInflateThenVictim_cannotRob` | 同一ブロック inflate→被害者入金でも搾取不能 |
| ⑦ | `test_DoS_forceDetach_succeeds_whenWithdrawReverts` | withdraw revert でも force-detach 成立 |
| ⑦ | `test_DoS_forceDetach_succeeds_whenTotalAssetsReverts` | totalAssets revert でも force-detach 成立 |
| ⑦ | `test_DoS_emergencyShutdown_alwaysSets_evenWhenAdapterFullyFrozen` | 完全凍結 adapter でも shutdown flag は必ず立つ |
| ⑦ | `test_DoS_shortfallPausesUser_thenForceDetachRestoresExit` | shortfall は一時 pause で恒久 brick でない→detach 後に全員 pro-rata 退出 |
| ⑦ | `test_DoS_vaultFullyOperational_afterForceDetachAndReattach` | detach→健全 adapter 再結線で完全復旧（brick は一過性） |
| ⑧ | `test_SG_vault_hasNoPermitFunction / hasNoDomainSeparator / hasNoNonces` | vault に署名面が存在しない（cross-chain replay 対象ゼロ） |

---

## ② アクセス制御 — 分類

| # | ベクター | 判定 | 根拠（1行） |
|---|---|---|---|
| AC1 | 特権関数の未保護 | **安全確認済** | 全 setter に `onlyGovernance`；shutdown は guardian\|gov（有効化）/gov（解除）。`harvest`/`collectFees` は**意図的 permissionless**＝delta 計測 / feeRecipient への mint 限定で資金搾取不能。adapter `rescueToken`/`pause`/`setSlippageBps` も inline gov。PoC 網羅 revert。 |
| AC2 | 初期化乗っ取り | **安全確認済** | `initialize` 無し＝constructor 専用・非 upgradeable proxy。front-run/二重初期化 N/A。 |
| AC3 | 権限昇格 | **安全確認済** | ロール階層なし（gov＋guardian=pause 専用）。low→high 経路なし。 |
| AC4 | governance 鍵モデル | **要提案(ops)** | 本番＝Timelock(48h)＋2-of-3 Safe guardian（`PRE_AUDIT_HARDENING` C-1・deploy script は EOA gov で revert）。単一鍵漏洩の最悪影響＝**registry に登録済**の adapter への切替のみ（任意 adapter 注入には register も要 gov）。悪意 adapter 登録は AC10 の registry 信頼前提＝Timelock 48h が検知窓。→ `REMEDIATION_PROPOSALS` AC4。 |
| AC5 | keeper 権限 | **安全確認済(スコープ外)** | DCA keeper はオフチェーン（`affliate-api` cron）＝凍結 repo に無し。keeper は user の ERC-20 approve 内で `deposit` を叩くのみ・share は受益者へ・share allowance 未付与で横取り不能（4重ロック・SCOPE §3）。 |
| AC6 | feeRecipient/treasury 変更 | **安全確認済** | `setFeeRecipient` は gov＋zero-check。feeRecipient は新規 mint の fee share を受けるのみ（上限 5%/yr×elapsed）・既存資金を引けない。 |
| AC7 | 2-step 所有権移転 | **安全確認済** | `proposeGovernance`→`acceptGovernance`（zero-check・renounce 経路なし）。PoC で原子的移転・旧 gov 無力化を実証。guardian は 1-step だが zero-check。 |
| AC8 | timelock＋event 可観測性 | **✅ FIXED(P2)** | timelock は gov 層（外部 TimelockController・PoC `TimelockGovernance.t.sol`）。**P2 で `setManagementFee`→`ManagementFeeUpdated`・registry gov 移転→`GovernanceProposed`/`GovernanceAccepted` を追加**（`setPerformanceFee` は P4 で無効化＝無音状態なし）。 |
| AC9 | pause/unpause 分離 | **安全確認済** | PoC：guardian=pause のみ・unpause は gov のみ。 |
| AC10 | vault ブリック | **安全確認済(信頼前提明示)** | gov は **registry whitelist 済** adapter へのみルート可能。honest ユーザーを brick する経路は無し（force-detach/shutdown で常時退出）。悪意 adapter 登録は AC4 の gov 信頼前提＝Timelock で緩和。 |

## ③ 丸め・share算・インフレーション — 分類

| # | ベクター | 判定 | 根拠 |
|---|---|---|---|
| RD1 | first-depositor / donation インフレ | **安全確認済** | `_decimalsOffset()=9`（OZ 既定 0 より強化）＝virtual shares。PoC で被害者非搾取・攻撃者非利益。 |
| RD2 | 丸め方向 | **安全確認済** | OZ v5 全 convert が floor＝vault 有利。withdraw は `received >= toWithdraw` hard-require。 |
| RD3 | dust 反復 | **安全確認済** | PoC 200 往復で利益ゼロ・solvent 維持。 |
| RD4 | 直接 donation で share 価格操作 | **安全確認済** | PoC：寄付は既存 holder に帰属・非 insolvency・donor は share 0 で回収不能。 |
| RD5 | zero-share mint | **✅ FIXED(P1)** | 旧＝OZ v5 は `shares>0` gard 無し＝極小入金が dust を取り 0 share（自己負担・非 insolvency）。**P1 で `SIXXVault.deposit`/`mint` に `require(shares>0)` 追加＝revert 化**。PoC `test_RD5_zeroShareDeposit_nowReverts`。 |
| RD6 | insolvency（totalAssets < Σ請求） | **安全確認済** | echidna `value_non_creation`＋invariant `invariant_valueNonCreation`＋PoC `_assertSolvent`（`convertToAssets(totalSupply) <= totalAssets`）。 |
| RD7 | アダプター境界の精度損失 | **安全確認済** | 4 adapter とも実残高デルタ計測（agent 精査）＋`received >= toWithdraw`。 |
| RD8 | fee crystallize × 丸め | **安全確認済** | M-1 希薄化式＋crystallize-on-interaction。既存 fee-fairness PoC。 |
| RD9 | convert 単調性 / 価値非創出 | **安全確認済** | 既存 invariant＋echidna（極端値入力）。 |
| RD10 | decimals 不一致・極端値 | **安全確認済** | USDC 6 桁・offset 9→15 桁 share・vault は資産別。adapter の `USDE_TO_USDC_SCALE=1e12` 処理済。 |
| RD11 | virtual offset の大きさ | **安全確認済** | offset=9（OZ 既定 0 より大）＝十分。 |

## ④ オラクル・価格操作 — 分類（adapter 評価棚卸し）

| adapter | totalAssets の源 | 種別 | flash 操作 | 判定 |
|---|---|---|---|---|
| Aave V3 USDC | `aToken.balanceOf`（流動性 index） | (a) protocol 会計 | 不能（単調 index） | **安全確認済** |
| Venus USDT | `balanceOf × exchangeRateStored/1e18` | (a) protocol 会計 | 不能（stored rate・≤1block・過小報告） | **安全確認済**（OR6 Venus 解禁前 stale-rate sandwich は別ブロッカー） |
| Ethena sUSDe | `susde.convertToAssets × (1-slippageBps)` | (a) ERC-4626 償還 | 不能（spot を会計に持ち込まず） | **安全確認済**（haircut default 0.5%・cap `MAX_SLIPPAGE_BPS=300`=3% gov setter） |
| Pendle PT | `ptOracle.getPtToAssetRate`（TWAP・par-cap）／満期後 par | (b) **TWAP**（非 spot） | 不能（TWAP＋par cap・満期 par 償還） | **安全確認済**（OR2：`twapDuration` に in-contract 下限なし→将来注記） |

| # | ベクター | 判定 | 根拠 |
|---|---|---|---|
| OR1 | totalAssets が瞬間価格由来 / flash 歪曲 | **安全確認済** | 全 adapter が償還/index/TWAP-par。PoC：adapter へ直接送金でも vault NAV 不変。 |
| OR2 | Pendle 満期前 MTM | **安全確認済＋✅ 強化(P3)** | AMM spot は execution のみ・会計は TWAP を par で上限クランプ。`twapDuration` immutable＋deploy 時 `getOracleState` readiness。**P3 で `twapDuration >= 900`（15分）下限強制**を追加。 |
| OR3 | Ethena sUSDe 評価 | **安全確認済** | `convertToAssets`（vesting 反映・非 pool reserve）＋保守 haircut。 |
| OR4 | 評価方式棚卸し | **安全確認済** | 上表（Aave/Venus=protocol index・Ethena=ERC4626・Pendle=TWAP par）。 |
| OR5 | デペグ時 honest 低評価 | **安全確認済** | Ethena haircut で fair value 未満＝vault 有利・optimistic 不使用。 |
| OR6 | stale 検知 | **一部/受容** | Venus `exchangeRateStored` は ≤1block stale かつ過小報告（保守）。deposit sandwich は Venus 解禁前ブロッカー（既知）。 |
| OR7 | ADR-004 ④「外部 oracle を会計コアに持ち込まない」 | **安全確認済** | 会計コアに外部 oracle 無し・価格流入経路を全 adapter で列挙済（上表）。 |
| OR8 | 償還ベースでも flash 不能 | **安全確認済** | PoC：同一ブロック inflate でも搾取不能・adapter 直接 donation で NAV 不変。 |

## ⑦ DoS・stranding — 分類

| # | ベクター | 判定 | 根拠 |
|---|---|---|---|
| DoS1 | 無限ループ gas-DoS | **安全確認済** | 単一 adapter。`isActive` は O(1) mapping。`getActiveAdapters` は view 専用・on-chain 経路で未使用。 |
| DoS2 | 他者 withdraw を revert（griefing） | **安全確認済(受容)** | shortfall は当該ユーザーの一時 pause（liveness）で恒久でない。PoC：force-detach で退出復旧。 |
| DoS3 | 単一 bad adapter が vault 全体 brick | **安全確認済** | PoC：force-detach＋shutdown は withdraw/totalAssets が revert しても成立。 |
| DoS4 | DCA executeBatch の gas 肥大 | **スコープ外** | DCA は凍結 repo に無し（オフチェーン cron / feature branch）。 |
| DoS5 | 資金の恒久 stuck | **安全確認済(残余 external 明示)** | vault 層で恒久 stuck 無し（PoC：detach→再結線で完全復旧）。外部プロトコル内で真に凍結した分は external stranding＝force-detach が NAV から honest write-off（timelock 化 gov action・AdapterForceDetached）。adapter `rescueToken` は誤送 token 回収（position token は `require(token != aToken)` で touch 不能＝元本は動かせない）。 |
| DoS6 | 緊急退出が常に可能 | **安全確認済** | PoC：force-detach（withdraw/totalAssets revert 耐性）＋shutdown（完全凍結耐性）。 |
| DoS7 | illiquid adapter 下の部分引出 | **安全確認済** | `_recallFromAdapter` は `min(needed, available)` を引く＝部分引出 safe。 |
| DoS8 | 外部コールの gas griefing | **受容(低)** | adapter は gov whitelist（AC10/AC4 信頼前提）。force-detach の try/catch が影響を bound。 |
| DoS9 | 再入起因の revert ループ | **安全確認済** | 全 entry `nonReentrant`（REENTRANCY council 既済）。 |
| DoS10 | 強制 ETH 送付 / self-destruct | **安全確認済** | ETH 会計なし（asset は ERC-20）。`totalAssets` は token `balanceOf`＋adapter で `address(this).balance` 非依存＝強制 ETH で会計不動。 |

## ⑧ 署名・リプレイ — 分類

| # | ベクター | 判定 | 根拠 |
|---|---|---|---|
| SG1 | permit リプレイ（nonce/deadline） | **安全確認済(N-A)** | vault に permit 無し。PoC：`permit`/`DOMAIN_SEPARATOR`/`nonces` セレクタが全て存在しない（sxUSDC は plain OZ ERC20）。 |
| SG2 | 署名 malleability | **N-A** | scope 内に署名検証なし。 |
| SG3 | クロスチェーン・リプレイ | **安全確認済(N-A)＋将来設計注記** | vault に署名メッセージが無い＝replay 対象ゼロ。**将来 permit-forwarder（④ ADR-007）を足す場合は EIP-712 domain に必ず chainId を含める**こと。 |
| SG4 | permit front-run griefing | **N-A** | 同上。 |
| SG5 | 署名の使用箇所 | **スコープ外/検証済** | Privy/Permit2（`PRIVY_PERMIT2_VERIFICATION` 検証済）・DCA は ERC-20 approve（署名でない）。将来 forwarder に本節適用。 |
| SG6 | 資金移動署名の scope/上限 | **N-A(現)/設計注記** | 現状署名面なし。 |
| SG7 | EIP-712 domain 正しさ | **N-A(現)** | forwarder 導入時に name/version/chainId/verifyingContract を検証。 |
| SG8 | deadline 強制・nonce 管理 | **N-A(現)** | 同上。 |
| SG9 | 現状（Privy/Permit2）再確認 | **安全確認済** | 凍結 scope に on-chain 署名面ゼロ（PoC 確認）。 |

---

## Part B（是正・`REMEDIATION_PROPOSALS.md`）— ✅ 2026-07-11 SHIN 承認・実装済

新規 HIGH/MEDIUM 実バグは無し。以下 LOW/informational を SHIN 承認で実装（`contract-audit.sh` 全ゲート PASS 維持）：

1. **P1（RD5）**：`SIXXVault.deposit`/`mint` に `require(shares > 0, "VAULT: zero shares")`（zero-share dust 拒否）。✅
2. **P2（AC8-obs）**：`setManagementFee`→`ManagementFeeUpdated`、Registry gov 移転→`GovernanceProposed`/`GovernanceAccepted`。✅
3. **P3（OR2/⑤）**：Pendle `twapDuration_ >= 900`（≥15分 TWAP）下限強制。✅
4. **P4（⑥）**：`setPerformanceFee` を not-implemented revert 化（`0` は no-op 許容）・`MAX_PERFORMANCE_FEE` 撤去。✅
5. **P5（AC4）**：本番 mainnet は Timelock(48h)＋2-of-3 Safe 必須＝**本番前運用ゲート据え置き**（`docs/operations/mainnet-gate.md`）。⏸

> P1-P4 はハードニング最終形として **main へマージ・再凍結**（新 tip）→ `make-handoff.sh` で束再生成。P5 は本番デプロイ時ゲート。
