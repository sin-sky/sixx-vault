# LATEST TIP — 差分敵対的リパス (2026-07-12)

> 姿勢: 「修正が正しいことを確認する」ではなく **「この差分は未監査の新規コードだ、バグを見つけろ」**。
>
> **本版は SHIN の 6 点指摘を受けた第2版（v2）。** 初版の以下の誤りを訂正:
> - RINV-1 の兄弟探索が「修正パターン側」からで逆向きだった → **危険側から再列挙**。
> - RINV-6 を「Aderyn 件数一致」で判定していた → **baseline commit vs tip の finding 同一性**で再照合。
> - RINV-2 の「dust 到達不能」が主張のみだった → **極端NAVの PoC テストで実証**。
> - RINV-4 を無条件 PASS としたが fork 未実行だった → **非fork限定PASS に格下げ・fork を残存に明記**。
> - RINV-5 の「差分 89/89 kill」は `--match-contract '*'`（正規表現エラー＝異常終了）による**偽 kill**だった
>   → フィルタ無しで再実行。**L304 cap の 4 mutant は等価変異と判明**（証明付き）。

- **現 tip**: src `9fa9796` / docs `dca47bf`
- **ベースライン（最後にフル敵対パスを通した src tip）**: **`2e8f059`**（Round 6）。
  根拠: `9fa9796` の親 `286060c` は docs-only。`git diff 2e8f059..9fa9796 -- src/` == `..dca47bf -- src/`。
- **審査のみ / オンチェーン操作なし / 凍結 src 無改変**（`git diff --stat -- src/` == 空、検証済）。
- 追加は test/mock/doc のみ（本リパスで負テスト・PoC を追加、frozen src は不改変）。

差分規模: **4 ファイル / +59 / −15**。実コード変更 3 点（F-3 Ethena dust revert / F-1 Registry・Vault chain gate）＋ Venus doc-only。

---

## 1. RINV-1（やり直し）— 危険側からの兄弟経路探索

### 1A. F-1 chain gate の兄弟 — 「production で危険な操作」を全列挙し gate 有無を照合

grep したのは chainid ではなく、**本番チェーンで実行されると資金/権限に影響する全 external/public 状態変更関数**。

| 関数 | アクセス制御 | 自前 production gate | 必要か / 根拠 |
|---|---|---|---|
| `SIXXVault.proposeGovernance` | onlyGovernance | **✅ F-1** | 必要。governance 交代の入口。gate 済 |
| `AdapterRegistry.proposeGovernance` | onlyGovernance | **✅ F-1** | 必要。gate 済 |
| `SIXXVault.acceptGovernance` | `msg.sender==pendingGovernance` | 不要 | pending は propose 時に F-1 で検証済。二重 gate 不要 |
| `AdapterRegistry.acceptGovernance` | pending 限定 | 不要 | 同上 |
| `SIXXVault.setAdapter` | onlyGovernance + nonReentrant | 不要 | **推移的保護**: prod では governance=Timelock(F-1)＝48h。M-02 の狙い通り |
| `AdapterRegistry.registerAdapter` / `setAdapterStatus` | onlyGovernance | 不要 | 同上（M-02 コメントが明記する「48h 継承」対象そのもの） |
| `SIXXVault.setLockPeriod/setPerformanceFee/setManagementFee/setFeeRecipient/setGuardian/reopenDeposits` | onlyGovernance | 不要 | 推移的保護。fee は hard cap（3000/500bps）で bounded |
| `SIXXVault.setEmergencyShutdown` | activate=guardian∨gov / deactivate=gov | 不要 | activate は**資金保護方向**（recall＋deposit停止）。悪意 guardian でも DoS 止まりで窃取不可。deactivate は gov のみ |
| `SIXXVault.harvest` / `collectFees` | permissionless(nonReentrant) | 不要 | 呼出者に資金は渡らない。fee は feeRecipient のみに mint。利益は balance-delta 算定 |
| `SIXXVault.__atomicPushToAdapter` | `require(msg.sender==address(this))` | 不要 | **自己呼出限定＝バックドアでない**（外部到達不可） |
| **adapter×4 `proposeGovernance`** | `msg.sender==governance` | **❌ 無し** | **下記で個別評価** |
| adapter×4 `rescueToken` | governance | 不要 | position(susde/aToken/vToken/PT)・principal(asset) を**除外**（L-02）。窃取不可 |
| adapter×4 `setSlippageBps/setSwapper/setEstimatedAPY/pause/proposeVault` | governance | 不要 | 下記の推移的保護に含まれる |

**唯一 gate の無い危険側候補 = adapter の `proposeGovernance`（4 実装）**。adapter governance は
`rescueToken`（stray のみ）・`setSwapper`・`setSlippageBps`・`proposeVault`（vault 再指定＝資金経路）を握る。
これは M-02 と同じ資金クリティカル権限。**しかし production で hot-EOA には出来ない**:

- `SIXXVault.setAdapter`（M-03）は `IAdapterBindings(newAdapter).governance() == governance` を強制（best-effort try/catch、
  実 adapter は governance() を公開）。∴ 配線時、prod では **adapter.governance == vault.governance == Timelock**。
- 配線後に adapter governance を EOA へ移すには `adapter.proposeGovernance(EOA)` を **現 governance=Timelock が呼ぶ**必要が
  ある ⟹ Timelock の 48h 遅延＋キュー可視。∴ M-02 の 48h 検出窓は **推移的に維持**される。
- 悪意 adapter が `governance()` を revert させて M-03 を回避しても、まず registry ホワイトリスト（H-1・onlyGovernance＝
  Timelock）を通す必要がある＝二重防御。

→ **adapter `proposeGovernance` に自前 chainid gate が無いのは正当**（推移的に 48h 窓を継承）。RINV-1 違反ではない。
残存観察としてのみ §6 に記録（防御多重化の任意提案）。

### 1B. F-3 dust guard の兄弟 — 「share 換算で 0 に丸まりうる清算経路」を全列挙

grep したのは "dust guard がある場所" ではなく、**partial 引出でサイズを share/token 数に換算する全経路**。

| adapter | partial 引出のサイズ計算 | 0 丸め時の旧挙動 | 現状 |
|---|---|---|---|
| **Ethena** | `sharesToSell = convertToShares(targetUsde)` | `==0 → 全 position 清算`（危険） | **F-3 で `require(>0)` 追加＝修正済** |
| **Pendle** | `ptToLiq = ptBal*buffered/ptMarkUsdc` | — | **既に `require(ptToLiq>0,"dust")`**（F-3 の手本） |
| **Venus** | `redeemUnderlying(assets)`（**share 換算せず** assets 直接） | — | 該当型なし。dust は Venus 側が "redeemTokens zero" で revert（全清算に落ちない） |
| **Aave** | `amount = assets>=bal ? max : assets`（**share 換算なし**） | — | 該当型なし。aavePool が処理 |

→ 「サイズ→0→全清算」型は **Ethena が唯一**で修正済、Pendle は既済。Venus/Aave は assets 直接指定で
該当せず（dust は各プロトコルが revert）。**未修正の兄弟経路なし。RINV-1 PASS。**

---

## 2. RINV-6（やり直し）— finding 同一性による baseline↔tip 照合

初版の「件数一致」を廃し、**baseline commit `2e8f059` と tip `dca47bf` を別々の git worktree で解析し、
finding を同一性（検出器＋関数）で照合**した（＝差分が新規指摘を生んだかを直接測る。現行の凍結
slither-baseline は `960b707` で差分後に再凍結済のため、tip 対 現baseline では差分由来を検出できない）。

### Slither（`slither .`、High/Medium ゲート）
- baseline High/Med = **43 件**、tip = **43 件**。check 別内訳も一致
  （reentrancy-balance 8 / divide-before-multiply 3 / incorrect-equality 10 / reentrancy-no-eth 1 /
  uninitialized-local 6 / unused-return 15）。
- `slither-check.py`（sha256 `id` 照合）では tip に 7 件が「baseline に無い」と出るが、内訳は**全て差分が
  触れた関数**（`VenusUSDTAdapter.withdraw` / `EthenaSUSDeAdapter.{totalAssets,deposit,withdraw}`）で、
  **行シフトにより id が再ハッシュされただけ**。
- **行番号を無視した (check, 関数) の multiset は baseline↔tip で完全一致（差分 = ∅）**。
  ```
  identical (check,function) multiset? True
  in TIP not baseline: []
  in BASELINE not tip: []
  ```
  → 差分由来の新規 High/Medium は **ゼロ**（同一性で確定、件数一致ではない）。

### Aderyn 0.6.8（High/Medium ゲート、exit 0）
- baseline: High=1 検出器（`Reentrancy: State change after external call`）、Medium=**0**。
- tip:      High=1 検出器（同上）、Medium=**0**。
- ファイル別 High インスタンス分布が baseline↔tip で**完全一致**
  （Aave 1 / Ethena 1 / Venus 1 / AdapterRegistry 1 / SIXXVault 16）。新規検出器・新規インスタンスなし。
- 初版で見えた「Misused boolean @ Ethena:305」は、**背景 mutation タスクが変異体(`if(false)`)を src に
  置いた瞬間を読んだ競合アーティファクト**と特定（clean tip では非再現）。

→ **RINV-6 PASS（同一性照合）**。差分は Slither/Aderyn いずれにも新規 High/Medium を導入しない。

---

## 3. RINV-2（追加検証）— dust guard が正当引出を巻き込まないことを極端NAVで実証

dust guard は `convertToShares(grossed-up target)` が 0 に丸まるとき（＝sUSDe 価格が天文学的なとき）のみ発火。
**最小の partial 引出（assets = 1 = 1e-6 USDC）が各極端状態で dust revert しないこと**をテストで実証した
（`test/EthenaSUSDeAdapterUnit.t.sol`、全 PASS）:

| シナリオ | テスト | 状態 | 結果 |
|---|---|---|---|
| (a) 大幅 write-off（share 価格極小） | `test_F3_extremeNAV_afterWriteOff_minWithdraw_noDustRevert` | rate −50% / −99.9% | dust revert せず（rate 低下は convertToShares を**増やす**＝更に安全） |
| (b) 大幅利益（share 価格極大） | `test_F3_extremeNAV_afterHugeGain_minWithdraw_noDustRevert` | rate ×1000 | dust revert せず（1000×＝数世紀分の利回りでも余裕） |
| (c) first-depositor（低 totalSupply） | `test_F3_extremeNAV_firstDepositor_partialWithdraw_noDustRevert` | $2 seed | dust revert せず |
| (d) 極小 totalAssets ＋ 最小引出 | `test_F3_extremeNAV_tinyTotalAssets_minWithdraw_noDustRevert` | $2 seed, assets=1 | dust revert せず |
| 境界の定量化 | `test_F3_dustGuard_thresholdIsBeyondAnyRealisticRate` | rate=1e21 安全 / rate=2e30 で初発火 | 発火閾値 ≈ **1e30（≈1e12× の増価）＝経済的に不可能** |

- 緊急退出/force-recall は `assets >= totalAssets()` の full-exit 分岐を通り、dust guard の**影響外**（別テスト
  `StressExitFreeze` 系で green）。
- **revert しうる正当状態は 1 つも見つからず**＝「到達不能」を実証（撤回不要）。grief/DoS 影響なし。RINV-2 PASS。

---

## 4. RINV-4（範囲明記）— 非fork 限定 PARTIAL PASS

- 実行したのは **非fork スイートのみ**: `forge test --no-match-contract Fork` = **280 passed / 0 failed**
  （初版 272 ＋ 本リパス追加 8 = 280）。INV-1..9 / MINV / DINV / TINV / 全 PoC / ThreatCouncil を含む。
- **fork スイート（Aave/Ethena/Pendle/Venus ForkTest）は未実行** — この環境に `.env`（`ARB_RPC_URL` 等）が
  無いため。Halmos 記号証明 2 件は green。
- ただし差分は fork 経路に影響しない: fork suite は `proposeGovernance/acceptGovernance` を**一切呼ばず**（grep 済、
  F-1 非該当）、Ethena fork の dust 面は §3 の unit PoC で被覆。
- **判定: RINV-4 は非fork限定 PARTIAL PASS。fork 未実行を残存リスクとして記録**（RPC 環境で
  `--fork-url $ARB_RPC_URL` / `$BNB_RPC_URL` を回すこと。特に `EthenaSUSDeAdapterForkTest`・`VenusUSDTAdapterForkTest`）。

---

## 5. RINV-5（詳細）— 差分行 mutation の逐件結果

> 方法論訂正: 初版の「89/89 kill」は `--match-contract '*'`（regex エラーで forge 異常終了）による
> **偽 kill**。フィルタ無しの**実**フル非fork スイートで再実行した正しい結果が以下。詳細は
> `audit/MUTATION_TRIAGE.md`（2026-07-12 追補）。

### 到達可能な差分行の mutant = 全 kill
| 位置 | mutant | 変異 | 判定 | kill したテスト |
|---|---|---|---|---|
| Ethena L310 dust | 372/373/374 | require 削除 / true / false | **KILLED** | `test_F3_dustWithdraw_*` / `test_F3_dustGuard_threshold*` |
| Registry L128 gate | 141 | `if(true)`（testnet で誤 gate） | **KILLED（本リパスで解消）** | **追加**: `test_F1_registry_proposeGovernance_nonProduction_allowsEOA` / `_defaultChain_allowsEOA` |
| Registry L128 gate | 142 | `if(false)` | KILLED | 既存 `test_F1_registry_*_rejectsEOA` |
| Vault L625/L655 gate | 996/997 等 | `if(true/false)` 他 | KILLED | 既存 `test_M02_vault_*` / `test_F1_vault_*` |

> **141 は初版で scoped 生存**（ThirdReviewRemediation に registry の testnet→EOA 許容テストが欠落、vault のみ存在）。
> 本リパスで registry 版を追加し **diff-local で kill**。これが「scoped 生存 5 件」の 1 件目。

### scoped 生存 5 件の内訳と最終判定
| # | 位置 | 変異 | 初版 scoped | 最終（実フル） | 対応 |
|---|---|---|---|---|---|
| 1 | Registry L128 | `if(true)` (141) | 生存 | **KILLED** | negative test 追加（上記） |
| 2 | Ethena L304 cap | `if(false)` (358) | 生存 | **SURVIVED＝等価** | 等価証明＋回帰ガード |
| 3 | Ethena L304 cap | delete→assert(true) (366) | 生存 | **SURVIVED＝等価** | 同上 |
| 4 | Ethena L304 cap | `sharesToSell=0` (367) | 生存 | **SURVIVED＝等価** | 同上 |
| 5 | Ethena L304 cap | `sharesToSell=1` (369) | 生存 | **SURVIVED＝等価** | 同上 |

**L304 cap（`if (sharesToSell > shares) sharesToSell = shares`）の等価証明**:
partial 分岐でのみ実行。cap 発火 ⟺ `convertToShares(targetUsde) > shares` ⟺ `targetUsde > convertToAssets(shares)`。
`targetUsde = assets·SCALE·MAX_BPS/(MAX_BPS−slip)`、`totalAssets() = convertToAssets(shares)·(MAX_BPS−slip)/MAX_BPS/SCALE`
（**同じ slip で haircut**）⟹ cap 発火 ⟺ `assets > totalAssets()`。だが partial は `assets < totalAssets()` のみ。
∴ **cap は partial 分岐で決して発火しない**（gross-up と haircut が相殺）。境界 `assets==totalAssets()` は full-exit 分岐。
baseline `2e8f059` にも同じ cap（複合条件版）が存在＝**差分が新規に生んだ test gap ではない**。等価変異ゆえ kill 不能だが、
回帰ガード `test_F3cap_maxPartial_sellsSubSlice_neverOversells_norDusts`（最大 partial でも過剰売却/dust しない）で pin。

→ **到達可能な差分行は全 kill。唯一の生存は証明済み等価（不活性 defense-in-depth）。無テストの到達可能新規コードはゼロ。RINV-5 PASS。**

---

## 6. RINV-3 / 残存観察

- **RINV-3（相互作用）PASS**: `_isProductionChain()` は Registry/Vault でバイト一致（drift なし）。F-1 は timelock 検査・
  2-step transfer と非衝突。F-3 は M13-16 shortfall guard・slippage floor と独立。二重適用/順序依存なし。
- **観察1（既存設計・非違反）**: 両 constructor は governance を gate 外で直接 set。baseline も同一＝差分非導入。
  初期 governance は deploy script が信頼境界で wire する genesis 操作で、遡って遅延を課す「前 governance」が存在しない。
- **観察2（任意の防御多重化・非違反）**: adapter `proposeGovernance` は自前 gate 無しだが M-03＋Timelock 48h で推移的保護（§1A）。
  更なる硬化を望むなら adapter 側にも `_isProductionChain` gate を足せるが、**behavior 変更ゆえ escalate 対象**で、
  凍結コードには入れない（Part B にも実バグとしては挙げない）。

---

## RINV 別 最終判定

| INV | 判定 | 根拠（証拠ベース） |
|---|---|---|
| RINV-1 修正の完全性 | ✅ PASS | 危険側全列挙。gate 無しは adapter proposeGovernance のみ＝推移的保護で正当。F-3 兄弟の全 share 換算経路照合済 |
| RINV-2 新面の無害 | ✅ PASS | 極端NAV(a-d)＋境界 PoC で dust guard が正当引出を revert しないと実証。閾値 ≈1e30 |
| RINV-3 相互作用安全 | ✅ PASS | `_isProductionChain` バイト一致・非衝突・二重適用なし |
| RINV-4 挙動非退行 | ⚠️ **非fork限定 PARTIAL PASS** | 非fork 280 green＋Halmos 2 証明。**fork 未実行（RPC 無し）＝残存** |
| RINV-5 fix 被テスト性 | ✅ PASS | 到達可能差分行 全 kill（141 は追加 test で解消）。L304 cap は証明済み等価 |
| RINV-6 静的解析クリーン | ✅ PASS | baseline↔tip の finding **同一性**照合で新規 High/Med ゼロ（Slither multiset 一致・Aderyn 分布一致） |

---

## 収束判定（曖昧表現を排す）

- **差分の実バグ・取りこぼし兄弟経路・新面の悪化は検出ゼロ。RINV-1/2/3/5/6 は証拠付き PASS。**
- **ただし RINV-4 は非fork限定 PARTIAL PASS。fork スイート未実行（この環境に RPC 無し）が唯一の未閉塞点。**
- **Part B（REMEDIATION_PROPOSALS.md）への実バグ追加は無し**（観察2 の防御多重化は behavior 変更ゆえ提案化せず escalate 扱い）。
- 凍結 src 無改変・オンチェーン操作なし。追加は test/mock/doc のみ。

> **結論**: この差分面は、**静的解析・mutation・極端NAV・危険側兄弟探索の全てで新規違反ゼロ＝実質収束**。
> **完全収束の宣言は RINV-4 の fork 実行（RPC 環境）を残条件とする** — それまでは「fork 未実行を残存とする条件付き収束」。
