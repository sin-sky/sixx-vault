# Proactive Adversarial Hardening Pass — 2026-07-12

> 対象: 凍結 src `2e8f059`（tag `audit-freeze-ed1e1d6`）に対する**内部・自発的** adversarial 再レビュー。
> 手法: コンポーネント別に並列 adversarial reviewer を fan-out（Aave / Ethena / Venus 各 adapter・
> AdapterRegistry ＋ deploy wiring）。全 finding は本体側で**個別に手検証**してから採否を決定。
> ベースライン: 264 tests green → 本パス後 **272 tests green**（+8 回帰テスト）。fork スイートは別途 RPC 必要。

---

## 採用（修正実施済み）

### F-1 — M-02 の Timelock 強制ゲートが Ethereum(chainid 1) でしか発火せず、**本番 Arbitrum One / BNB では無効** 〔Medium〕

- **所在**: `SIXXVault.proposeGovernance`（旧 `if (block.chainid == 1)`）／`AdapterRegistry.proposeGovernance`（同型）。
- **根拠**: `script/Deploy.s.sol` は **Arbitrum One (42161)** と **BNB Chain (56)** を本番 mainnet として扱い、
  実 2-of-3 Safe＋48h TimelockController を配線する（`Deploy.s.sol:34-47, 124-133, 153-162`）。ところが M-02 の
  「mainnet governance は必ず 48h Timelock」強制は `chainid==1` のみ。**本 vault の主戦場は Arbitrum One**
  （CLAUDE.md の live デプロイは Arbitrum Sepolia、fork テストは `ARB_RPC_URL`）であり、そこで governance を
  生 EOA に移譲でき、M-02 の 48h 検知窓が黙って無効化される。既存テストは `vm.chainId(1)` のみで gap 不可視。
- **修正**: 両コントラクトに `_isProductionChain()`（`{1, 42161, 56}`）を追加し `chainid==1` を置換。deploy が
  本番配線する chain 集合と一致。testnet/local（Sepolia・Arb Sepolia・BNB testnet・31337）は従来どおり EOA 可。
- **回帰テスト**（`test/ThirdReviewRemediation.t.sol`・全 green）: Arbitrum One/BNB での EOA 拒否・24h Timelock 拒否・
  48h Timelock 受理（vault＋registry）、Arbitrum Sepolia は EOA 継続許可。計 7 本。TDD で先に red 化を確認。
- **保守メモ**: 本番 chain 集合が 3 箇所（`Deploy.s.sol`・`SIXXVault._isProductionChain`・
  `AdapterRegistry._isProductionChain`）に分散。新 chain 追加時は 3 箇所同時更新が必要（将来 gap の再発点）。

### F-3 — Ethena 部分 withdraw のダスト時、**全ポジション清算にフォールバック** 〔Info→防御的修正〕

- **所在**: `EthenaSUSDeAdapter.withdraw`（旧 `if (sharesToSell > shares || sharesToSell == 0) sharesToSell = shares;`）。
- **根拠**: 部分 exit で `convertToShares(targetUsde)` が 0 に丸まると、旧コードは**ポジション全量**を売却して
  ダスト要求に全額返す。現行 sUSDe レート(~1.1)では非到達（各 share が ~1e6 USDe 相当という極端な再デノミが必要）
  だが、`==0 → 全売却` は驚き最大・危険なフォールバック。full exit は上位の `assets >= totalAssets()` 分岐が担うため、
  ここに 0 shares で到達する＝要求が過小 → **revert が正**（Pendle の `require(ptToLiq > 0, "dust")` と同型）。
- **修正**: `if (sharesToSell > shares) sharesToSell = shares; require(sharesToSell > 0, "ADAPTER: dust");`。
- **回帰テスト**（`test/EthenaSUSDeAdapterUnit.t.sol::test_F3_dustWithdraw_reverts_insteadOf_drainingAll`・green）:
  レート極大化でダスト要求 → `"ADAPTER: dust"` revert かつポジション不変をアサート。TDD red 先行。

### コメント精度修正（コード挙動は不変）

- **Venus `totalAssets()`**: staleness を「~1 block(~3s)」と誤記 → 実際は「直近の Venus 操作以降の未収利息」
  （idle market は分〜時間 lag しうる）。経済的に無視可能な結論は不変、magnitude 表記のみ是正。
- **Ethena `totalAssets()` header**: 「100% recall は必ず reported 以上を実現」という**不変条件の言い過ぎ**を是正。
  convertToAssets は Ethena 内部の peg-blind レートで、haircut(≤3%)は通常 AMM slippage のみをカバー。
  haircut を超える depeg 下では DEX 実現額 < mark で当該性質は崩れる旨を明記（＝開示済み depeg リスク、
  緊急停止 force-detach で write-off＋deposit pause により封じ込め、haircut では封じない）。

---

## 却下（誤検知・仕様どおり）

| 指摘 | 判定 | 理由 |
|---|---|---|
| Aave: adapter `pause()` が deposit を revert させる | ❌ 誤検知 | `_deployToAdapter` の M-3 `try/catch`（`SIXXVault.sol:332-336`）が adapter revert を吸収。資金は idle に留まり deposit は**成功**。レビュアは try/catch を見落とし。 |
| Aave/Venus/Ethena: 直送 underlying が回収不能 | 仕様 | L-02（rescueToken が underlying を保護）の意図的トレードオフ。攻撃者=寄贈者自身の損のみ、share price 不変。 |
| Aave: `rescueToken` が非 nonReentrant | Info | governance 限定＋aToken/asset ブロックで完全封じ込め。第三者不達。 |
| Registry: `_adapterList` append-only・cap は生涯登録数 | Low | `registerAdapter` は onlyGovernance、重複登録ブロック済み。攻撃者 griefing 経路なし。100 は現実値を大きく上回る。 |

---

## 決定済（運用緩和で対応・SHIN 判断 2026-07-12）

### F-2 — Ethena NAV が可変 `slippageBps` に連動し、slippage 変更時に **NAV 段差＝裁定機会** 〔Medium・条件付き〕

> **決定（SHIN・2026-07-12）＝選択肢 (A) 運用緩和のみ。** NAV haircut のコード脱連結は行わない（ADR-007 #1 の
> 意図的設計・6 回監査通過済で回帰リスク大）。代わりに `docs/operations/mainnet-gate.md` G3 に恒久チェックを追加：
> (1) Ethena vault の `lockPeriod` 非ゼロ化で round-trip を封鎖（H-2/H-4）、(2) `setSlippageBps` 変更は前後で
> deposit pause。監査人へは既知リスクとして本 doc で開示。

- **所在**: `EthenaSUSDeAdapter.totalAssets()`（`* (MAX_BPS - slippageBps)`）× `setSlippageBps`。
- **機序**: `totalAssets` が public 可変ノブ `slippageBps` の純関数。depeg 収束後に `300→50` へ tighten すると
  NAV が単一 tx で ~2.5% 跳ね上がる。adapter `requiredLockPeriod()==0` のため、**vault の `lockPeriod` が 0 なら**
  「tighten 直前 deposit → 直後 redeem」で既存 holder から最大 ~2.5%(−実 DEX 2脚)を抽出可能。実 depeg 不要。
- **成立条件と緩和**:
  1. governance の slippage 変更が必要（本番は 48h Timelock 経由＝48h 前公示。裁定を防がず、むしろ予告する）。
  2. **vault `lockPeriod > 0` なら H-2/H-4 のロックで round-trip 不成立**（＝最有力の運用緩和）。deploy 既定は 0。
  3. 抽出量は 3% cap で有界、被害者は既存 holder。直接 drain ではない（希薄化）。
- **なぜ本パスで未修正か**: NAV を haircut する設計は ADR-007 #1 の**意図的決定**（full-drain shortfall guard を
  満たすため）で、6 回監査を通過済み。NAV と可変ノブの脱連結は shortfall-guard 不変条件・既存スイートに回帰リスク。
  一方 slippage を可変に保つこと自体が depeg 時の exit 継続の要（＝トレードオフの核心）。**独断で再設計しない。**
- **選択肢（SHIN 判断）**:
  - (A) **運用緩和のみ**（推奨・低リスク）: Ethena vault の `lockPeriod` を非ゼロに設定し F-2 と一般 JIT を同時封鎖。
    さらに slippage 変更手順に「変更前後は deposit pause」を runbook 化。コード変更なし。
  - (B) **コード脱連結**（高リスク）: NAV haircut を固定 immutable 化し swap slippage と分離。full-drain guard の
    再設計を伴い、回帰テスト全面見直しが必要。
  - (C) 現状維持＋開示（F-2 を既知リスクとして監査人へ明示）。

---

## 変更ファイル

```
src/core/SIXXVault.sol            F-1: _isProductionChain() 追加・chainid==1 置換
src/core/AdapterRegistry.sol      F-1: 同上
src/adapters/EthenaSUSDeAdapter.sol  F-3: dust revert / F-1: header コメント精度
src/adapters/VenusUSDTAdapter.sol    staleness コメント精度
test/ThirdReviewRemediation.t.sol    F-1 回帰 7 本
test/EthenaSUSDeAdapterUnit.t.sol    F-3 回帰 1 本
```

## 再現

```bash
forge test --evm-version cancun --no-match-contract Fork   # 272 passed
forge test --evm-version cancun --match-test 'test_F1_'    # F-1 回帰
forge test --evm-version cancun --match-test 'test_F3_'    # F-3 回帰
```
