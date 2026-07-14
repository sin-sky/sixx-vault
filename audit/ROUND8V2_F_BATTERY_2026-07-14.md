# Round-8 v2 — 裁定 F(idle-only burn-price skim)修正の全 battery 結果

**凍結候補**: `06e13c9`(F guard 修正)+ `5fd0ff2`(slither baseline 再凍結・audit metadata のみ)
**src ハッシュ対象**: `src/` は `06e13c9` で確定、`5fd0ff2` は `src` 無改変(clean-tree ガード green)。
**評価日**: 2026-07-14 / evm=cancun / solc=0.8.28 / foundry 1.7.1

> **一本化の担保**: 全ステージを **同一の凍結 `src` ツリー**(clean-tree ガードが「src == committed source」を各回検証)
> に対して実行。foreground 10 分上限のため実行は複数コマンドに分割したが、**`src` はステージ間で一切変化していない**
> (唯一の非 src 変更 = slither baseline 再凍結は解析対象外の allowlist メタデータ)。分散ツリーの green 寄せ集めではない。

## ステージ結果(全 green)

| ステージ | 結果 | 詳細 / 証跡 |
|---|---|---|
| 0a clean-tree ガード | ✅ PASS | `src` == committed、mutation 生成物なし |
| 0b on-chain ガード回帰 | ✅ PASS | cast send / forge --broadcast を block、benign 許可(stdin+env+schema canary) |
| 0c measurement-tooling 回帰 | ✅ PASS | clean-tree + mutation-canary 6 ケース green |
| 1 build | ✅ PASS | 89 files, solc 0.8.28, 成功 |
| 2 test(非-fork) | ✅ **323 / 0** | 30 suites。新規 `ExitSkewIdleOnlyBurnPriceF` 含む |
| 3 coverage | ✅ PASS | `src/core/SIXXVault.sol` **line 97.79%(266/272)** > 85% 閾 |
| 4 invariant | ✅ **25 / 0** | value 非創造 / shares-backed / non-custody / monotonicity |
| 5 echidna | ✅ **8 props passing / falsified 0** | 両ハーネス完走 `--test-limit 50000`。`value_non_creation`・`non_custody_no_idle`・`shares_backed`・`totalAssets_never_reverts`・`no_phantom_cross_adapter`・`pause_blocks_deposit` |
| 6 slither | ✅ PASS(0 new) | 15「新規」= 14 行シフト再配置 + 1 b835c09 良性 probe。**本 commit の新クラス 0**。baseline 再凍結(`5fd0ff2`)、triage `audit/SLITHER_TRIAGE.md` |
| 7 aderyn | ✅ PASS | High **1**(triaged baseline FP)= 閾、Medium **0** = 閾 |
| 8 halmos | ✅ **2 / 0** | `check_depositCreatesNoValue`(∀)・`check_redeemNeverExceedsDeposit`(∀, 466 paths) |
| 9 fork(実RPC・per-chain) | ✅ **43 / 0**(6 suites) | Aave ARB/ETH・Venus BSC・Ethena sUSDe・Pendle PT・**EthenaLargeExitGraceful**(大口 graceful 非劣化) |

## 修正固有の敵対的検査(全 green)

- **skim = 0 wei 実証**: `test/ExitSkewIdleOnlyBurnPriceF.t.sol` — 修正前 alice 4735.96 / bob 4264.04(skim 471.9 ≈ 10.5%)
  → 修正後 **alice = bob = 4500(skim 0)**。haircut 0(9k 全額分配・stranding 0)。
- **回帰強化(見逃し是正)**: `ExitSkewRevertFallbackC::test_C_revertFallback_guard_idlePositive_noBurnPriceSkim` —
  idle>0 + loss で **7000 / 7000**。旧テストは idle==0(0/0 自明)でしか公平性を主張せず見逃していた gap を封鎖。
- **diff-mutation 全 kill(3/3)**: `!emergencyShutdown` 除去 → H-02 shutdown テストが kill(1 fail) /
  `&&`→`||` → healthy 経路 kill(6 fail) / catch 無力化(guard dead)→ skim 再発を 2 テストが kill(2 fail)。
- **平常系 1-wei 不変**: readable 分岐は構造的に無変更(新 `if` を素通り、try 本体不変)。
- **新規攻撃面なし**: internal 関数、既存 state `emergencyShutdown` を読むのみ、新規 external call / storage / 再入なし。
