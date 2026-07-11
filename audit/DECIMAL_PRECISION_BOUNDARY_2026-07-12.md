# decimal / 精度境界 監査 — 換算・丸めの数値面（正典）

> 区分: 🟢 done。2026-07-12。Part A（本番 src 無改変・凍結 `2e8f059`／test・mock・doc のみ）。
> 対象: 桁跨ぎ換算・丸めでの価値漏れ/搾取（DINV-1〜6）。**境界 fuzz（6/8/18 桁）＋ Halmos 記号証明**。
> 設計元＝`threads/code_audit/DECIMAL_PRECISION_BOUNDARY.md`。①状態遷移・③複数adapter とは別テーマの一区画。

---

## 結論

**新規の実バグ = ゼロ。DINV-1〜6 は全桁・全境界で保持（収束）。**
特に **最小桁(6) × 極値（1 wei / 桁境界 / 1e9 token）× first-depositor** で DINV-1/2/4 が崩れないことを実証。
share↔asset 往復が入力を超えないこと（丸めは常に vault 有利）を **Halmos で全 amount について記号的に証明**した。

---

## 0. 桁の棚卸し（実 src 判定）

| 対象 | 桁 | 根拠（src） |
|---|---|---|
| **vault asset** | USDC/USDT=**6**（現行デプロイ全て）。LBTC=8 / sUSDe・ETH建て=18 は**将来資産**（未デプロイ・コードは decimal 非依存） | Deploy 各 script・CLAUDE.md（1 vault=1 asset） |
| **share** | asset 桁 + **固定 offset 9**（USDC→15 / 8桁→17 / 18桁→**27**） | `_decimalsOffset()=9`（SIXXVault L673・OZ ERC4626 virtual-shares） |
| **Aave adapter** | totalAssets = `aToken.balanceOf`（=asset 桁 6・aUSDC 1:1 rebasing）。**ray(1e27) 換算は adapter 内に無い**（Aave 内部） | `AaveV3USDCAdapter.totalAssets` |
| **Venus adapter** | totalAssets = `vBal(8) × exchangeRateStored(mantissa 1e18) / 1e18` → underlying(6)。**mul-then-div /1e18・floor（過小=vault 有利）** | `VenusUSDTAdapter` L136 |
| **Ethena/Pendle** | sUSDe/PT(18) ⇄ USDe(18) ⇄ USDC(6) を `×/÷ 1e12`・Pendle rate 1e18・sUSDe `convertToAssets`(18) | Pendle `_usdeToUsdc`/`_usdcToUsde`・Ethena adapter |
| **swapper** | USDC(6) ⇄ USDe/sUSDe(18) を `×/÷ 1e12` | `IStableSwapper` 実装（外部・注入） |
| **fee** | `feeAssets = assets × bps × elapsed / (1e4 × SECS_PER_YEAR)`／`feeShares = feeAssets × supply / (assets − feeAssets)`（**mul-before-div**・BPS 1e4） | SIXXVault L555-561 |
| **_totalDebt / totalAssets fallback** | asset 桁（**桁跨ぎ無し**＝booking aid） | H-01/H-02 fix |

### 桁が跨ぐ箇所（叩く対象）
- **P1 share↔asset**（offset 9・asset 桁 6/8/18）＝**vault コア・全資産共通**（最重要）。
- **P2 adapter index/rate**（Venus 1e18・Pendle rate 1e18・18↔6）＝adapter 内部。
- **P3 swapper 6↔18**（×/÷1e12）＝外部注入。
- **P4 fee**（1e4・mul-before-div）＝vault。
- **P5 fallback**（桁跨ぎ無し）。

---

## 実装物（Part A・src 無改変）

| ファイル | 役割 |
|---|---|
| `test/DecimalPrecisionBoundary.t.sol` | **6/8/18 桁 mock asset**（`DecToken`）で vault コアを境界 fuzz。DINV-1〜6 を fuzz/deterministic で検査（各 1000 runs） |
| `test/halmos/SIXXVaultSymbolic.t.sol` | `check_redeemNeverExceedsDeposit` 追加＝**往復 ≤ 入力を全 amount で記号証明**（DINV-2/4） |

> P2（Venus 1e18・Pendle rate）・P3（swapper 18↔6）の adapter 内部換算は、既存の adapter unit/fork スイート
> （`VenusUSDTAdapterUnit`・`PendlePTAdapterAdversarial`・各 Fork）が往復・floor 方向を検証済み。本監査は
> **全資産共通の vault コア（P1/P4）を多桁で総ざらい**する位置づけ。

---

## 検査した DINV

| DINV | 内容 | 実装 | 判定 |
|---|---|---|---|
| **DINV-1** 丸め漏れ非蓄積 | 境界桁での deposit↔withdraw 反復で他者資産を dust 吸出不能（griefer は 300 サイクルで純利益ゼロ・honest holder 非希薄化） | `test_DINV1_dustCyclesCannotSkim` | ✅ |
| **DINV-2** 丸めは vault 有利 | 全 convert がユーザー不利側 floor・redeem で pro-rata 超を受領不能（後入り depositor が rounding で skim 不能） | `testFuzz_roundTrip_*`・`testFuzz_noSkim_*`・Halmos | ✅ |
| **DINV-3** sub-precision guard | 0 share に丸まる入金は revert（`require(shares>0)`が全桁で有効・free dust なし） | `test_DINV3_subPrecisionDeposit_reverts`・roundTrip の `shares>0` | ✅ |
| **DINV-4** 桁跨ぎ正当性 | 往復（asset→shares→asset）が入力を超えない・off-by-decimal / mul-div 順序ミスなし | `testFuzz_roundTrip_{6,8,18}`・**Halmos 記号証明** | ✅ |
| **DINV-5** 極値安全 | 1 wei / 桁境界(10^d±1) / 1e9 token で overflow(0.8 checked)・insolvency・phantom share なし | `test_DINV5_extremes`（6/8/18 × 6 境界） | ✅ |
| **DINV-6** fee 精度 | fee 計算が桁境界で価値生成/喪失せず（collectFees で asset 側不変・feeRecipient 請求 ≤ 正当額） | `testFuzz_fee_{6,18}` | ✅ |

## Halmos 記号検証（fuzz より強い保証）

```
[PASS] check_depositCreatesNoValue(uint256)      (paths: 3)
[PASS] check_redeemNeverExceedsDeposit(uint256)  (paths: 25)   ← DINV-2/4：往復 ≤ 入力を全 amount で証明
Symbolic test result: 2 passed; 0 failed
```

`check_redeemNeverExceedsDeposit` は share mulDiv（非線形・offset 9）を含む往復を、範囲内の**全 amount**について
「redeem 受領 ≤ deposit 額」を証明（sampled でなく∀）。→ **丸めは常に vault 有利**が形式的に保証された。

## 発見・残存

**新規の実バグ = ゼロ。残存＝なし。** 6/8/18 桁 × 境界値 × first-depositor × fee で DINV-1〜6 が全 green、
うち DINV-2/4 は Halmos で∀証明。offset 9 の virtual-shares により first-depositor inflation・dust skim は
経済的に不能であることを多桁で再確認。

### 非空（vacuous 回避）の担保
- DINV-1 は griefer の**実残高の純変化**を測る（`balanceOf(griefer) ≤ initialFund`）＝実 leakage 測定。
- DINV-2/6 は**注入 yield で share 価格を非整数化**してから丸めを engage（丸めが実際に働く経路を通す）。
- DINV-5 は 6/8/18 桁 × 6 境界（1wei/2wei/10^d−1/10^d/10^d+1/1e9token）を明示列挙。

## 再現・実行

```bash
forge test --match-contract DecimalPrecisionBoundary   # DINV-1..6（6/8/18 × 1000 runs）
forge clean && halmos --function check_ --contract SIXXVaultSymbolic  # DINV-2/4 記号証明（Stage 8b）
./scripts/contract-audit.sh                            # OVERALL PASS
```

## Part B（該当なし）

DINV 違反（実バグ）は発見されなかったため、`REMEDIATION_PROPOSALS.md` への新規追記なし。
凍結 src（`2e8f059`）無改変。**「新規違反ゼロ＝精度境界面も収束」**と結論する。
（将来 8/18 桁資産を実デプロイする際は本監査面が既に多桁で green のため回帰安全。offset は全桁固定 9。）
