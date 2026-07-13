# README FOR REVIEWER — SIXX Vault 監査ハンドオフ入口

> **これ1枚が外部監査／専門レビューの入口**です。詳細スコープは `audit/SCOPE.md`。
> 本書は既存 `AUDIT_PACKAGE.md`（ベンダー向け詳細索引）を**置き換えず補完**します（入口を1枚に集約）。

---

## 0. 一言サマリ

ERC-4626 vault が、ガバナンス whitelist された **1 adapter** 経由で単一原資産を運用。実資金（USDC/USDT 等）
を扱う。**自前 Solidity 3,156 行 / 17 ファイル**が監査対象（`audit/SCOPE.md`）。

---

## 1. 凍結コミット（監査対象スナップショット）

| 項目 | 値 |
|---|---|
| repo | `github.com/sin-sky/sixx-vault` |
| **監査対象コード凍結（Round 7・内部 adversarial hardening 形）** | **`9fa9796`**（**F-1** M-02 の Timelock 強制を本番チェーン集合 `{Ethereum 1, Arbitrum One 42161, BNB 56}` に拡張＝deploy が本番配線する Arbitrum One/BNB の盲点を閉塞／**F-3** Ethena 部分 exit の dust は全清算せず revert／F-2 NAV×可変 slippage 裁定は運用緩和＝lockPeriod＋slippage 変更 pause。詳細＝`audit/ADVERSARIAL_HARDENING_2026-07-12.md`） |
| 前 Round | `2e8f059`（Round 6・第3レビュー H-02/M-02/M-03/L-02/L-03） / `0703525`（Round 5・第2独立レビュー H-01/M-01/L-01/P-02/P-03） / `78aa8c1`（Round 4・独立 Handoff 監査 M-01〜M-05／L-01） / `173e3fb`（Round 3・Part B P1-P4） |
| 本ハンドオフ束 | `9fa9796` 近傍 HEAD。zip 名の末尾 shorthash＝バンドル生成コミット |
| solc | **0.8.28** |
| Foundry | forge **1.7.1** |
| OpenZeppelin | **v5.6.1**（`lib/openzeppelin-contracts`） |
| forge-std | **v1.16.1**（`lib/forge-std`） |

> 以降の変更は監査ベンダーと合意の上で。本ハンドオフ zip は凍結 `9fa9796` の内容を同梱。

---

## 2. ビルド／テスト手順（再現可能）

```bash
# 0) Foundry（forge/cast/anvil を v1.7.1 に pin）
curl -L https://foundry.paradigm.xyz | bash
foundryup -i v1.7.1

# 0.5) 監査ツールチェーン（pinned・contract-audit.sh / mutation / halmos / echidna 用）
#   ★ バージョンを固定しないと aderyn 等が別ビルドになり exit 101 で panic する。
#     下の 0.8) verify で全ツール PASS を確認すること（正典＝scripts/verify-audit-toolchain.sh）。
#   -- Python 系（slither/solc/crytic-compile/halmos）を隔離 venv に（Linux/macOS 共通）--
python3 -m venv /opt/audit-venv
/opt/audit-venv/bin/pip install \
  "slither-analyzer==0.11.5" "solc-select==1.2.0" "crytic-compile==0.3.11" "halmos==0.3.3"
for b in slither solc-select solc crytic-compile halmos; do \
  sudo ln -sf /opt/audit-venv/bin/$b /usr/local/bin/$b; done
solc-select install 0.8.28 && solc-select use 0.8.28
#   -- prebuilt バイナリ（Rust 不要・Linux x86_64。★macOS は各 release の *-apple-darwin tarball に置換）--
curl -fsSL -o /tmp/aderyn.tar.xz \
  https://github.com/Cyfrin/aderyn/releases/download/aderyn-v0.6.8/aderyn-x86_64-unknown-linux-gnu.tar.xz \
  && tar -xJf /tmp/aderyn.tar.xz -C /tmp \
  && sudo install -m0755 "$(find /tmp -maxdepth 2 -name aderyn -type f | head -1)" /usr/local/bin/aderyn
curl -fsSL -o /tmp/echidna.tar.gz \
  https://github.com/crytic/echidna/releases/download/v2.3.2/echidna-2.3.2-x86_64-linux.tar.gz \
  && tar -xzf /tmp/echidna.tar.gz -C /tmp \
  && sudo install -m0755 "$(find /tmp -maxdepth 2 -name echidna -type f | head -1)" /usr/local/bin/echidna
sudo curl -fsSL -o /usr/local/bin/gambit \
  https://github.com/Certora/gambit/releases/download/v1.0.6/gambit-linux-v1.0.6 && sudo chmod +x /usr/local/bin/gambit

# 0.8) 版一致を検証（全ツール PASS を確認。aderyn は exit 0 が正常）
./scripts/verify-audit-toolchain.sh
#   ↳ どうしても aderyn が当該プラットフォームで panic (exit 101) する場合のみ：
#     ADERYN_ADVISORY=1 ./scripts/contract-audit.sh  （aderyn を manual-review WARN に降格。
#     PASS を偽装しない＝Slither が主ゲートのまま。詳細は §4.4）

# 1) 依存（zip 同梱の lib/ をそのまま使う場合は不要。git clone から始める場合のみ）
#    git submodule update --init --recursive
#    （OZ v5.6.1 / forge-std v1.16.1 に pin 済み）

# 2) 必須環境変数：既定 EVM=osaka は panic するため cancun を固定
export FOUNDRY_EVM_VERSION=cancun

# 3) ビルド & 非フォークテスト（RPC 不要）
forge build
forge test --no-match-contract Fork          # 272 pass 想定（invariant/fuzz 含む）

# 4) ワンコマンド決定論監査（推奨・静的解析＋不変条件＋Echidna＋差分ゲート）
./scripts/contract-audit.sh                    # OVERALL PASS を確認
./scripts/contract-audit.sh --mutation         # ＋ mutation（会計コア・低速）
./scripts/contract-audit.sh --halmos           # ＋ Halmos symbolic pilot

# 5) フォークテスト（要 実 RPC。.env に ETH/ARB/BNB RPC を設定）
#    cp .env.example .env  # 値を埋める（本 zip に .env は含めない）
forge test --fork-url $ARB_RPC_URL --match-contract AaveV3AdapterForkTest
```

`contract-audit.sh` のステージ：solc 固定 → build → test → coverage ゲート（会計コア ≥85%）→
invariant → Echidna → **slither baseline 差分（新規 High/Med で fail）** → aderyn。詳細は ADR-006。

---

## 3. 重点レビュー箇所（優先度順）

1. **会計コア（`SIXXVault.sol`）— share/asset 丸め**
   - `_decimalsOffset()=9`（OZ virtual-shares）による first-depositor インフレ緩和。
   - 丸めが常に **vault 有利（ユーザー切り捨て）** か。`convertToShares/Assets` の mul-then-div 順序。
   - **M-1 fee 希釈式** `feeShares = feeAssets*supply/(assets-feeAssets)`（`previewDeposit` に戻さない）。
   - lock（H-2/H-3/H-4）と `maxWithdraw/maxRedeem` の 0 返し。
   - 不変条件は `test/invariant/`＋`test/echidna/`＋`test/halmos/` に形式化（価値非創出／換算整合／非カストディ／単調性）。

2. **連携境界（adapter → 外部呼び出し）**
   - 戻り値非依存の**実残高デルタ会計**＋`require(received >= toWithdraw)`（M13-16）。
   - swap 境界：Ethena=Curve StableSwap-NG、Pendle=Router V4＋注入 `IStableSwapper`。スリッページ上限・満期前後の価格評価（満期後は額面償還）。
   - M-3：`__atomicPushToAdapter` 自己呼び出しで reverting adapter を封じ込め（資金 idle 保持）。

3. **非カストディ境界**
   - `withdraw(assets, recipient)` の直送。プロダクト側ウォレット経由の資金移動が無いこと。

4. **DCA keeper 信頼前提**
   - 積立実行はオフチェーン NestJS cron（本 repo に keeper コントラクト無し）。keeper は「approve 範囲で `deposit` を叩く」のみ＝**資金付け替え権限なし**（share は受益者へ発行）。keeper 鍵濫用の最悪影響が approve 上限までの入金トリガに限定されることの確認。

5. **ガバナンス（C-1）**
   - TimelockController(48h)＋guardian(2-of-3 Safe)。`setEmergencyShutdown` の非対称化（ON=guardian 即時／OFF=Timelock）。`setAdapter` の registry 強制（H-1、`address(0)` は明示 pause）。

6. **【ADR-007 ①②③ 実装済＝本ラウンドの主対象 — 内部 Threat Council 2026-07-11 由来】** 詳細＝`audit/THREAT_COUNCIL_2026-07-11.md`＋workspace `ADR-007`。以下は**実装済で監査対象**（旧「open question」から更新）：
   - **① 退出 liveness**：force-detach（`setAdapter(0)` best-effort try/catch・migration は strict）＋`setAdapter`/`setEmergencyShutdown` の totalAssets 耐障害化＋Ethena governance slippage setter（default 50・cap 300bps）。PoC＝`test/StressExitFreeze.t.sol`。**レビュー観点＝force-detach の NAV write-off が timelock 化 governance のみ・migration の strict 維持・totalAssets try/catch の網羅。**
   - **② profit-streaming**：locked-profit degradation（`harvest()`/`lockedProfit()`/`totalAssets` 減算・8h 線形）。PoC＝`test/ProfitStreaming.t.sol`。**観点＝continuous adapter は lock 0（後方互換）・discrete gain の buffer・丸め。**
   - **③ fee crystallize**：deposit/withdraw/setManagementFee 冒頭で `_collectFees`（CEI）。PoC＝`test_collectFees_lateDepositor_notDiluted_afterCrystallize` 他。**観点＝変換前 crystallize の順序・M-1 希釈式保存。**
   - **④ permit forwarder は別ラウンド**（vault は非カストディ・無欠陥。keeper/frontend/custody-auditor 管轄）。本監査の対象外。
   - **① ストレス時の退出/移行 liveness（HIGH・ADR-007 #1 ミニマム実装済）**：`received >= mark`（M13-16）で realizable<mark 時に出金/detach/shutdown が凍結していた問題に対し、**force-detach（`setAdapter(0)` の try/catch best-effort・migration は strict 維持）＋`setAdapter`/`setEmergencyShutdown` の totalAssets 耐障害化＋Ethena governance slippage setter（default 50・cap 300bps）**を実装（SHIN 承認 2026-07-11）。PoC＝`test/StressExitFreeze.t.sol`（force-detach 成功→ユーザー pro-rata 退出／shutdown が totalAssets-revert でも成立）＋Ethena setter 4本。**残（②③④＝profit-streaming / fee crystallize / permit forwarder）は次ラウンド。** レビュアーへ：force-detach が未回収残余を NAV から write-off する設計トレードオフ（timelock 化された governance action）への見解を求む。外部監査はハードニング最終形（②③④後）に1回実施予定。
   - **② 離散収穫アダプター解禁時の JIT 復活（構造）**：本体に profit-streaming 未実装。現行4アダプターは連続 accrual ゆえ安全だが、報酬請求型アダプター whitelist で JIT 復活。運用規約で「連続 accrual のみ解禁可」を暫定担保。
   - **③ 手数料の未 crystallize（MEDIUM）**：`collectFees` が相互作用時にチェックポイントされず後入 depositor が希薄化。PoC＝`test_collectFees_KNOWNISSUE_lateDepositorDilutedForPriorPeriod`。

---

## 3.5 レビュアーへの Open Questions（②③④⑦⑧ 合議の残論点）

`THREAT_COUNCIL_REMAINING_2026-07-11.md` の合議で **新規 HIGH/MEDIUM 実バグは検出されず**（②③④⑦⑧ 全ベクター安全確認済 or 既知運用/将来スコープ）。新規 PoC＝`test/ThreatCouncilRemaining.t.sol`（28本）＋`test/RemediationPartB.t.sol`（7本）・非フォーク全 **272 本 green**（現行・非fork 全体）。

拾った LOW 3件は **✅ 2026-07-11 SHIN 承認で実装済**（`REMEDIATION_PROPOSALS.md`・`contract-audit.sh` 全ゲート PASS）：
1. **RD5（P1・FIXED）**：`SIXXVault.deposit`/`mint` に `require(shares>0)`＝zero-share dust 入金を revert 化。
2. **AC8 event（P2・FIXED）**：`setManagementFee`＋registry gov 移転に event 追加。
3. **OR2 Pendle twapDuration（P3・FIXED）**：`>= 900`（15分）下限強制。
4. **⑥ performanceFee（P4・FIXED）**：not-implemented revert 化。

レビュアーに見解を求めたい残論点：
- **AC4 registry 信頼前提**：gov（本番=Timelock+2-of-3 Safe）は registry 登録済 adapter へのみルート可能だが、register 権限で悪意 adapter 登録→切替は理論上可能（Timelock 48h が検知窓・P5 本番前ゲート `docs/operations/mainnet-gate.md`）。この信頼境界の許容度。
- **⑧ 将来 permit-forwarder**：現 vault は署名面ゼロ（cross-chain replay 対象なし）。④ で permit-forwarder を足す際、EIP-712 domain に chainId 必須（本書＋合議に設計注記済）。

---

## 4. 既知の偽陽性（FP）・等価変異 — **追わなくてよい**

これらは既に逐条トリアージ済み。**新規の指摘だけに集中**してください。

### 4.1 Slither（`audit/SLITHER_TRIAGE.md`＋`AUDIT_PACKAGE.md §Slither`）
- **reentrancy-balance（High）**：全経路 `nonReentrant` 配下＋外部先は Aave/Venus/標準 USDC/USDT（コールバック無し）＝攻撃者コードに制御が渡らない。**確定 FP**。
- **incorrect-equality / unused-return / divide-before-multiply / timestamp / missing-zero-check(`address(0)`=registry無しモード) 等**：いずれも意図的設計 or FP（逐条は `SLITHER_TRIAGE.md`）。
- ゲートは **baseline 差分**（`audit/slither-baseline.json`）＝**新規 High/Med のみ fail**。既知分は許容リスト化済み。

### 4.2 Mutation（`audit/MUTATION_TRIAGE.md`）
- 会計コア mutation：
  - ⚠️ **現行 headline = フル 1,090-mutant run＝score 94.6%（killed 1031 / survived 59, seed=0）。** 生存 59 はいずれも**設計上の等価変異**（`_totalDebt`/`performanceFee` 等）＋**低 severity の negative/telemetry テスト欠落**で、安全性 invariant は非破壊。
  - ✅ **再検証済（2026-07-12, S0-1）**: 硬化ハーネス（pre-flight canary が invocation 健全性を確認）で正しい invocation により再実行し、**94.6% / 1031 / 59 を厳密一致再現＝看板は正当**。as-run ログ＝`audit/mutation-full-1090-evidence-2026-07-12.md`（生存 59 件全記録・単一ソース）。測定器の修理は `audit/MEASUREMENT_TOOLING_FIX_2026-07-12.md`。
  - ✅ **汚染時間帯照合済（2026-07-13, S0-1 追検証）**: 共有 working tree 汚染（2セッション同時）の発覚を受け、看板 run の実行窓を git reflog / セッション transcript 時刻で照合。看板 run は単一セッション窓（`f0fb3c76`, 07-12）で完結し、共有tree汚染（07-13）とは **非重複＝汚染なし・有効**。恒久対策は隔離 worktree 強制＋全ラン src-freeze 検証（[`docs/operations/ADR-008`](../docs/operations/ADR-008-one-session-one-worktree.md)）。
  - （旧・参考）**60 サンプル×会計コア限定 run**（seed=0 / N=60）：raw 96.7%（killed 58 / survived 2）／等価 2 件を除く実効 100%。**この "実効 100%" は当該旧サンプル run の値で、現行 headline ではない。**
  - 逐条＝`audit/MUTATION_TRIAGE.md`（冒頭スコープ注記参照）。
- **残る生存2件は等価変異＝kill 不可能**（コード位置で照合すること・番号は seed 依存）：
  - **EQ-2 `collectFees` の `if (elapsed==0) return 0;`**：`elapsed==0` なら按分手数料が数式上 0 ＝ 早期 return を消しても観測挙動一致。
  - **EQ-1 `_recallFromAdapter` の `if (activeAdapter==0) return;`**：`idle>=assets` が先に return＝`activeAdapter==0` は全額 recall 後にのみ成立ゆえ**到達不能**。
- それ以外の survived が出たら**新規 test gap**として扱ってください。

### 4.3 意図的な実装制約（`AUDIT_PACKAGE.md §5`）
- `performanceFee` は settable だが accrual 未使用（現状 management fee のみ）。
- 非標準/fee-on-transfer/rebasing トークン非対応（標準・非 rebasing の USDC/USDT 等のみ）。

### 4.4 Aderyn（`audit/ADERYN_TRIAGE.md`）
- **Aderyn High-1「Reentrancy: State change after external call」（15 インスタンス）＝確定 FP**。内訳：
  `setAdapter`（9）・`harvest`（3）は **`nonReentrant` 配下**、Aave/Ethena/Venus の **constructor**（3）は
  **再入不能**（デプロイ完了前）。
- **Slither との cross-check 済**（`ADERYN_TRIAGE.md §3`）：setAdapter/harvest は Slither も非 exploitable 区分
  （`reentrancy-no-eth`/`-benign`/`-events`）で検出、constructor は Slither が所見化すらせず。
  **コードベース全体で `reentrancy-eth`（exploitable）は 0 件**（両ツール一致）。
- ⚠️ **レビュアーへ依頼**：静的解析ツールの限界を踏まえ、上記 **reentrancy FP 判定の独立確認**（特に
  `setAdapter` force-detach の try/catch 経路と `harvest` の balance-delta 経路）をお願いします。
- ツール信頼性：**aderyn 0.6.8 で完走（exit=0）・決定的（High=1/Med=0）**。`contract-audit.sh` Stage 7 は
  Slither を主ゲート・Aderyn を副次ゲートとし、**クラッシュ/不完全 run は PASS にならない**（report 無し/
  Issue Summary 無し→FAIL、exit≠0→WARN）よう保証。

---

## 5. 同梱物（この zip / repo audit/ 配下）

- `SCOPE.md` — in/out スコープと LoC。
- `README_FOR_REVIEWER.md` — 本書。
- `SLITHER_TRIAGE.md` — Slither 逐条 FP トリアージ（正典は workspace `threads/sixx-vault/`・本書は同梱コピー）。
- `ADERYN_TRIAGE.md` — Aderyn 逐条 FP トリアージ＋Slither cross-check＋ツール信頼性（0.6.8 完走）記録。
- `MUTATION_TRIAGE.md` — 生存ミュータント（等価変異）逐条。
- `THREAT_COUNCIL_2026-07-11.md` — 10攻撃面 合議レビュー（JIT 精査＋残存保全・PoC 参照・運用規約）。
- `THREAT_COUNCIL_REMAINING_2026-07-11.md` — 残る脆弱性型 ②③④⑦⑧（アクセス制御/丸め/オラクル/DoS/署名）の全面合議＋分類表＋新規 PoC 28本参照。**新規 HIGH/MEDIUM なし**。
- `REMEDIATION_PROPOSALS.md` — Part B 是正案（LOW/informational・凍結コード外・SHIN 承認待ち）。
- `slither-check.py` / `slither-baseline.json` — 差分ゲートと許容リスト。
- 併せて repo ルートの `AUDIT_PACKAGE.md` / `PRE_AUDIT_HARDENING.md` / `CLAUDE.md` / `slither-*.json` を参照。

> 秘密情報（`.env`・鍵・RPC・`broadcast/`）は本 zip に**含めません**。
