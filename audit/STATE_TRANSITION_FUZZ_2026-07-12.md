# 状態遷移 × 障害注入 系統的 stateful fuzz — 実施記録（正典）

> 区分: 🟢 done。2026-07-12。Part A（本番 src 無改変・凍結 `2e8f059`／テスト・ハンドラ・モックのみ）。
> 対象: 資金保護インバリアント INV-1〜INV-9 の総ざらい。**Foundry invariant ＋ Echidna の二エンジン**。
> 位置づけ: 直近 High（H-01 force-detach×NAV-revert 希薄化／H-02 shutdown×NAV-revert 退出不能）が
> 全て「状態遷移 × `totalAssets()`-revert」由来だったため、**あらゆる操作順序 × 障害状態**を機械で総当たりし
> 収束（新規違反ゼロ）を実証する。設計元＝`threads/code_audit/STATE_TRANSITION_FUZZ.md`。

---

## 結論

**新規の実バグ = ゼロ。INV-1〜INV-9 は全順序 × 全障害で保持（収束）。**
fuzz は 2 件の反例を発見したが、**いずれもハーネスの判定ロジックの誤り（vault のバグではない）**で、
判定を精緻化して解消（下記「発見」）。特に **`totalAssets()`-revert × 全遷移で INV-1／INV-2／INV-5 が
崩れないこと**を Foundry（5 invariant × 256 runs × depth 40 ＝ 各 10,240 calls）＋ 決定論チェーン 4 本
＋ Echidna 4 property で実証した。

---

## 実装物（Part A・src 無改変）

| ファイル | 役割 |
|---|---|
| `test/mocks/FaultInjectingAdapter.sol` | 障害ノブ付き adapter（`revertOnTotalAssets`／`revertOnWithdraw`／`deliverBps`(lossy)／`realizeLoss`(実損)／`addYield`）。`vault()/governance()/asset()` を露出し M-03 binding 検証を通過。`realBalance()` で真の残高を可視化（判定精緻化用） |
| `test/invariant/StateTransitionHandler.sol` | 全ライフサイクル操作を fuzz アクション化＋ ghost 集計＋ INV 違反フラグ。健全 adapter プール(4)を migrate/reattach で循環 |
| `test/invariant/StateTransitionFuzz.t.sol` | INV-1〜INV-9 の Foundry invariant（重み付け＝`totalAssets`-revert × exit）＋ 決定論チェーン 4 本（非空証明・PoC 兼用） |
| `test/echidna/StateTransitionEchidna.sol` | 別エンジン cross-check（solvency core 4 property・単一 actor＝harness） |
| `scripts/contract-audit.sh` | Stage 5 で echidna を 2 ハーネス実行に拡張 |

---

## 探索したアクション（順序は fuzzer 任せ）

deposit / mint / withdraw / redeem / **第三者 transfer** / **approve 経由 第三者 redeem** /
harvest(vault) / addYield(profit) / realizeLoss / setManagementFee(0↔非0) / setPerformanceFee /
collectFees / setAdapter(migrate) / **setAdapter(0)=force-detach** / setEmergencyShutdown(on/off) /
reopenDeposits / adapter reattach。3 アクター（早逃げ・後入り・第三者）。

## 障害注入ノブ（シーケンス途中で切替）

- **`totalAssets()` revert**（本命・H-01/H-02 の根源）
- `withdraw()` revert（完全凍結）
- lossy 受領（`deliverBps` < 100%＝realizable < mark／stale mark）
- realizeLoss（実損・デペグ／破綻＝残高が送金なしに恒久減）

> **スコープ外（設計上の非対応・SCOPE §2 / AUDIT_PACKAGE §5）**：rebasing／fee-on-transfer トークン。
> vault は標準・非 rebasing の USDC/USDT を前提とするため、これらは常時 invariant からは除外（含めると
> 「文書化済みの非対応」を violation として拾うだけで、実バグではない）。adapter/oracle 障害面（＝実 High の震源）に集中。

## 検査した INV（全到達状態で常時真）

| INV | 内容 | 実装 | 判定 |
|---|---|---|---|
| **INV-1** 常時退出 | `totalAssets` revert 下でも、資産が実在し adapter が渡せる限り redeem/withdraw が**実際に assets を受領**して成功。完全凍結/実損は force-detach 救済に帰着 | Foundry invariant + chain 1 | ✅ |
| **INV-2/3** 非希薄化/solvency | `convertToAssets(totalSupply) ≤ totalAssets`（over-claim/insolvent 不能） | Foundry + Echidna + chain 3 | ✅ |
| **INV-4/6** 価値非創出/honest NAV | `totalAssets ≤ Σ入金＋Σ利回り−Σ引出`（JIT 往復含む・デペグ前額面早逃げ不能） | Foundry + Echidna + chain 4 | ✅ |
| **INV-5** pause 整合 | impaired（depositsPaused/shutdown/NAV unreadable）で `maxDeposit==maxMint==0`・希薄化 mint なし | Foundry + Echidna + chain 2 | ✅ |
| **INV-7** fee 公平 | fee 0↔非0・順序不問で遡及/回避/非保有期間希薄化なし（INV-2/4 が fee toggle 下でも保持＝これを含意） | Foundry（fee toggle をアクション化） | ✅ |
| **INV-8** detach/reattach 安全 | 任意順序×障害で希薄化なし・honest write-off 超の stuck なし・健全 reattach で復旧（`activeAdapter≠0 ⟹ !depositsPaused`） | Foundry invariant + chain 3 | ✅ |
| **INV-9** governance 連鎖安全 | 合法 governance 操作の任意の並びが文書化トレードオフ超の害を出さない（INV-1..8 が全順序で保持＝これを含意） | 全 invariant の連言 | ✅ |

## 発見（＝2 件・いずれもハーネス誤判定・vault バグではない）

fuzz が INV-1 で 2 反例を発見。**両者とも「exit が revert したが、その revert は文書化された正しい挙動」**を
ハーネスが誤って違反フラグにしていたもの。判定を精緻化して解消（vault は正しく動作）。

1. **realizeLoss × `totalAssets`-revert（最小 4 手）**：`deposit → faultRevertTotalAssets(true) →
   realizeLoss(全額) → redeem`。adapter の資金が**実際に全損**したが `totalAssets` revert で計測不能 →
   fallback(`_totalDebt`)が NAV を過大表示 → その過大請求に対する redeem を vault が正しく拒否（他ユーザーを
   奪わないため）。**これは force-detach 救済モデル（write-off 後に残余を pro-rata 退出）で、liveness バグではない。**
   → 判定を「請求額 ≤ 実回収可能額（idle + adapter 実残高）」のときのみ INV-1 違反、に精緻化（`realBalance()` 導入）。
2. **完全凍結 × 微少額（最小 3 手）**：`deposit(1 wei) → faultRevertWithdraw(true) → withdraw(1)`。
   凍結 adapter からの回収不能＝文書化された liveness pause。丸め許容 `+3` が微少請求を誤検知していた。
   → 厳密比較（`claimable ≤ recoverable`・許容なし）に修正。

**残存＝なし。** 上記修正後、Foundry 5 invariant（各 10,240 calls）＋ chain 4 本＋ Echidna 4 property が全 green。
反例を発見できたこと自体が、fuzz が「障害 × exit」面に実際に到達し INV を評価している（＝非空）ことの証拠。

## 非空（vacuous pass 回避）の担保

- Foundry invariant は run 間で handler 状態を setUp スナップショットへ revert する（＝cross-run の ghost 累積で
  カバレッジを測れない）。このため**カバレッジ主張は決定論チェーン 4 本**で行う：各チェーンは障害が**実際に発火**して
  いることを直接アサート（`_assertTotalAssetsReadReverts` で raw read が revert することを確認）した上で、
  **assets の実受領**（`got > 0` かつ balance デルタ一致）を検証。
- INV-1 は「revert で通った」ではなく「**実際に assets を受領した**」をアサート（chain 1）。
- 反例 2 件の発見が、fuzz の到達性（deposit→fault→loss→redeem 等）を実証。

## 再現・実行

```bash
# Foundry（invariant + 決定論チェーン）
forge test --match-contract StateTransitionFuzz -vv
# Echidna（別エンジン）
echidna test/echidna/StateTransitionEchidna.sol --contract StateTransitionEchidna --config echidna.yaml --test-limit 50000
# 全ゲート
./scripts/contract-audit.sh          # OVERALL PASS（test 240 / invariant 18 / echidna 7 props）
```

CI nightly は runs/depth を上げて実行想定（in-file `forge-config`: runs=256 depth=40）。mutation は隔離実行。

## Part B（該当なし）

INV 違反（実バグ）は発見されなかったため、`REMEDIATION_PROPOSALS.md` への新規追記なし。
凍結 src（`2e8f059`）は無改変。**「新規違反ゼロ＝このクラスは収束」**と結論する。
