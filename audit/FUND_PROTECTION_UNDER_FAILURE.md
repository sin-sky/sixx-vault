# Fund Protection Under Failure — SIXX Vault（2026-07-11）

> 資金保護レジリエンス分析。**「攻撃者が儲かるか」ではなく「最悪の障害時にユーザー資金がどう守られるか」** を、5つの障害シナリオで敵対的モックベース（fork/RPC 無し）に実証する。
> 対象：`SIXXVault` + `AdapterRegistry` + 外部 `TimelockController`（gov 層）。本番 `src/` 無改変＝**テスト/モック/doc のみ**。
> PoC＝`test/FundProtectionUnderFailure.t.sol`（全 `forge test --no-match-contract Fork` で常時走る・RPC 不要）。
> 関連：`THREAT_COUNCIL_2026-07-11.md`（① liveness）・`THREAT_COUNCIL_REMAINING_2026-07-11.md`（⑦ DoS/stranding）・ADR-007・`StressExitFreeze.t.sol`・`HandoffAudit.t.sol`。

---

## 資金保護4条件（各シナリオで全アサート）

| # | 条件 | 定義 | 破れたら |
|---|---|---|---|
| **(a)** | 回収可能 | 障害後もユーザーは（減価後の honest な取り分を）引き出せる。恒久 stuck 無し。 | 資金凍結 |
| **(b)** | 損失限定/隔離 | 損失は障害の起きた1アダプター（1戦略）に限定。他戦略・vault 会計コアへ伝播しない。 | 損失の伝播 |
| **(c)** | 公平社会化 | デペグ/破綻の **前** 評価での「早逃げ」＝残存者への損失押付けが **revert**。損失は全 holder に pro-rata。 | 早逃げ搾取 |
| **(d)** | 優雅劣化 | 全損しない。緊急バルブ（force-detach / emergency shutdown）は障害アダプターに **絶対 brick されない**。回収可能分は回収。 | 全損 / バルブ brick |

**保護を支える本体機構（凍結済 `src/`）**
- `totalAssets() = idle + adapter.totalAssets() − lockedProfit`：mark はアダプターの **live** 値。デペグ/損失は即座に全 holder の share 価格へ反映＝早逃げの時間窓なし。
- `_recallFromAdapter` の **`received >= toWithdraw` hard-require**：realizable < mark の fire-sale 退出を **revert**＝残存者へ haircut を転嫁できない。
- `setAdapter(0)` = **force-detach**（best-effort try/catch）：アダプターの `withdraw`/`totalAssets` が revert しても **常に** pause でき、回収額を book・残差は NAV write-off・`depositsPaused` で新規 mint を封鎖。
- `setEmergencyShutdown` は **フラグ先行 + try/catch recall**＝壊れたアダプターに valve を brick されない。
- gov は外部 `TimelockController(48h)`＝資金移動（`setAdapter`）は 48h 遅延。即時ドレイン経路なし。
- ERC-4626 virtual shares（offset=9）＝インフレ攻撃防御。

---

## シナリオ結果サマリ

| ID | 障害 | (a)回収 | (b)隔離 | (c)公平 | (d)優雅 | 判定 |
|---|---|:--:|:--:|:--:|:--:|---|
| **A2** | 外部プロトコル破綻（bad-debt/insolvency 注入） | ✅ | ✅ | ✅ | ✅ | **保護済** |
| **B1** | Ethena デペグ（sUSDe 評価急落） | ✅ | ✅ | ✅ | ✅ | **保護済** |
| **D1** | governance 危殆化 × Timelock 退出 | ✅ | ✅ | ✅ | ✅ | **保護済** |
| **E1** | 取り付け × illiquid（流動性枯渇） | ✅ | ✅ | ✅ | ✅ | **保護済**（liveness は受容） |
| **G1** | デプロイ後バグ × force-detach | ✅ | ✅ | ✅ | ✅ | **保護済** |

---

## A2 — 外部プロトコル破綻の隔離

**注入**：稼働アダプターに `simulateLoss()` で bad-debt（mark 低下＋トークン流出）を注入し、預り資産の一部を insolvency 化。

- **(a)** 損失後もユーザーは減価後の pro-rata を全員引き出せる（凍結なし）。
- **(b)** 損失はその1アダプターに限定。**別 vault＋別アダプター**の NAV は不変・その預金者は満額回収＝戦略間で損失が伝播しない。
- **(c)** 損失は注入と同時に mark へ反映＝全 holder の share 価格が同時に下落。損失 **前** の額面での `withdraw` は `ERC4626ExceededMaxWithdraw` で **revert**。早逃げした holder も遅れて出た holder も **等額**（損失は 50/50）。
- **(d)** NAV > 0（部分損失）。全損せず、回収可能分は honest に配分。

**残存リスク**：外部プロトコルの insolvency 額そのものは外部要因＝vault では防げない（隔離と公平配分のみ保証）。→ 運用＝アダプター解禁ゲート（監査済・連続 accrual のみ）＋TVL 上限。

## B1 — Ethena デペグの honest 会計

**注入**：sUSDe 評価（アダプター mark）を急落させ、デペグを模擬。

- **(a)** デペグ後の honest な減価額で全員回収可能。
- **(b)** 損失はデペグ幅に限定（例：−20% mark → −20% NAV）。会計コアに spot を持ち込まないので、pool 操作での追加損失なし。
- **(c)** **本命**：デペグ **前** の額面での早逃げ（sUSDe エクスポージャを par で他人へ押付け）は `maxWithdraw` 低下により **revert**。mark はデペグと原子的に更新＝先回り窓ゼロ。早逃げ者・残存者ともに等しい減価を負担。
- **(d)** NAV > 0。デペグ ≠ 全損。

**残存リスク**：デペグそのものは外部（Ethena）。vault は honest 低評価で早逃げを封じるのみ。満期前 Ethena は 0.5% 床＋7日 cooldown fallback＋runbook（外部受容・`THREAT_COUNCIL` 参照）。

## D1 — governance 危殆化 × Timelock 退出

**設定**：gov = `TimelockController(48h)`、proposer = 攻撃者（鍵漏洩）。攻撃者は資金を奪う `DrainAdapter` への `setAdapter` を狙う。registry は本 PoC では中立化し **Timelock を唯一の障壁として隔離**（H-1 whitelist は別レイヤ＝registry gov も同 Timelock 下）。

- **(a)** gov 危殆化中でも `withdraw` は **permissionless**＝ユーザーは 48h 窓で全額退出可能。
- **(c)** 攻撃者 EOA の直接 `setAdapter` は `VAULT: not governance` で revert。Timelock 経由でも遅延前 `execute` は revert（`activeAdapter` 不変）＝**即時ドレイン経路なし**。
- **(b)** ユーザーが窓内に退出済のため、攻撃者が 48h 後に `setAdapter(drain)` を執行しても **空の vault** ＝ユーザー損失ゼロ。
- **(d)** 退出経路が gov 危殆化に一切ブロックされない。

**残存リスク**：Timelock 窓中にユーザーが退出「しない」と資金は攻撃者の執行対象になる＝**監視＋通知運用が前提**（`docs/operations/mainnet-gate.md`：Timelock イベント監視・guardian による emergency shutdown）。guardian 鍵の分離（2-of-3 Safe）で pause は即時可能。

## E1 — 取り付け × illiquid

**注入**：mark は健全（損失ゼロ）だが引出流動性のみ枯渇するアダプター。全ユーザーが一斉引出。

- **(c)** **本命**：流動性を超える引出は `received >= toWithdraw` で **revert**＝早逃げ者が流動分を「fire-sale で満額」抜いて残存者へ haircut を転嫁できない。誰も pro-rata を超えて引けない（`maxWithdraw` 上限）。
- **(a)** 流動性回復後（または force-detach）に残りユーザーが満額回収＝**恒久 stuck 無し**。
- **(b)** insolvency ではなく illiquidity＝**損失ゼロ**（mark 不変）。詰まりは遅延であって毀損でない。
- **(d)** 部分流動性は部分退出に供され、回復で完全復旧。

**残存リスク**：即時全額退出の不成立＝**liveness の受容**（製品設計・`THREAT_COUNCIL` DoS2/DoS7）。UI で「一部運用中・順次引出」を開示。恒久化した場合は force-detach で NAV write-off して pro-rata 退出へ移行。

## G1 — デプロイ後バグ × detach

**注入**：稼働後にアダプターがバグ発症（`withdraw` 過少配送＝実現額 < mark、および `totalAssets` revert 型）。

- 通常 `withdraw` は `received < toWithdraw` で revert＝バグ発覚。
- **(c)** バグ発覚後、損失 **前** の額面での早逃げは revert＝writeoff 前に誰も満額退出できない。
- **(d)** governance が `setAdapter(0)` force-detach で隔離：`withdraw`/`totalAssets` が revert しても valve は成立（try/catch）。回収額を book・残差を NAV write-off・`depositsPaused` で新規封鎖。
- **(a)** detach 後、回収された分をユーザーが pro-rata で引出可能＝退出できる。
- **(b)** 損失は当該アダプターの未回収分に限定・write-off は全 holder に等分。

**残存リスク**：アダプター内で物理的に stuck した分は外部 stranding＝force-detach が NAV から honest に write-off（`AdapterForceDetached` イベント・timelock 化 gov action）。バグの再発防止＝解禁前監査＋段階 TVL。

---

## Part B（是正提案）— 現時点なし（新規 HIGH/MEDIUM 実バグ検出ゼロ）

5シナリオ全てで4条件を満たし、**本体コード改修を要する新規欠陥は検出されなかった**。残存リスクは全て「外部要因（デペグ/insolvency）」「受容済 liveness」「運用ゲート（Timelock 監視・アダプター解禁・TVL 上限）」に落ち、`THREAT_COUNCIL` / ADR-007 / `mainnet-gate.md` で既にカバー済。

**運用フォローアップ（コード不要・既存の再掲）**
1. Timelock（`GovernanceProposed`/`schedule`）とアダプター `AdapterForceDetached`/`AdapterRecallFailed` のオンチェーン監視 → guardian への即時通知。
2. アダプター解禁ゲート：連続 accrual・監査済のみ whitelist。TVL 上限を段階解放。
3. デペグ/illiquid runbook：床 revert 時の cooldown fallback・段階退出手順。
