# Threat Council — SIXX Vault（2026-07-11・JIT 精査＋10攻撃面 合議レビュー）

> オーケストレーター／プロトコルエンジニア／監査の合議（多役 adversarial: 発見→反証検証→統合）。
> 対象コミット近傍：`main`（監査対象コード凍結 `3917de7`）。本書は**保全の正典記録**（実装は下記の切り分けに従う）。
> 関連：`SCOPE.md`・`README_FOR_REVIEWER.md`・`MUTATION_TRIAGE.md`・`SLITHER_TRIAGE.md`・workspace `ADR-006`／`ADR-007(Proposed)`。

---

## 結論

- **JIT（同一ブロック往復益）は現行デプロイでは実質死んでいる**：4アダプター全て連続 accrual・`harvest()` は no-op・出入金手数料ゼロ＝前取りできる離散段差が存在しない。→ **JIT はこのままで良い**。
- ただし JIT の外側に **own-code の残存 HIGH が1件**：**ストレス時に資金を退出・移行できず凍結する（liveness）**。盗難でなく「de-risk したい瞬間に何もできない」。ここだけ本体/アダプター改修に値する。
- 他は low〜medium（手数料配分の公平性・一時的出金DoS・非カストディ未達）＝原理的に盗まれるものではなく、多くは将来アダプター解禁前ブロッカー or 運用/文書で閉じる。

---

## 既に保全済み（封じている機構）

| ベクター | 機構 |
|---|---|
| 古典 JIT（同一ブロック往復） | 連続 accrual／`harvest` no-op／出入金手数料ゼロ＝利益ステップ無し |
| 悪意アダプターすり替え | registry whitelist（H-1）＋Timelock 48h ＋ `lockPeriod=0` で即時退出 |
| 再入（deposit/withdraw/setAdapter/shutdown） | 全 `nonReentrant`／`totalAssets` は view→STATICCALL／資産・share フックレス |
| ロックグリーフィング（H-3） | `caller==receiver` 時のみロック書込 |
| first-deposit inflation | OZ v5 virtual shares `_decimalsOffset()=9` |
| 往復 dust 抜き | OZ 丸め vault 有利＋`received>=toWithdraw` |
| アダプター revert 隔離 | `__atomicPushToAdapter` try/catch（M-3） |
| Registry ループ DoS | `isActive` は O(1) mapping、`getActiveAdapters` は on-chain 未使用 |
| Keeper→share リダイレクト | share allowance 未付与モデルで `_spendAllowance` が revert |

---

## 残る要保全（優先順）＋ PoC 証拠

### ① 【HIGH・own_code】ストレス時のアダプター退出/移行の凍結 ★最優先
`received >= mark`（M13-16）を try/catch 無しで hard-require。realizable < mark（depeg/スリッページが haircut 超）になると **ユーザー出金・ガバナンス detach・`setAdapter(0)` が全て revert**。同根：
- **Ethena** `MAX_SLIPPAGE_BPS=50` は **constant・setter 無し**（Pendle には `<=300bps` setter あり）。
- **Pendle** `totalAssets` が TWAP par-cap を無 haircut 評価 → 全額退出が構造的に mark 割れ。
- **`setEmergencyShutdown`** の `adapter.totalAssets()` 読取が **try/catch 外** → totalAssets が revert する型（Pendle TWAP not-ready 等）でフラグ設定ごと巻き戻り＝valve が brick。`withdraw` 側は try/catch 済で shortfall には耐性。

**PoC（在 repo・全 green）＝`test/StressExitFreeze.t.sol`**：
- `test_stress_userExit_bricks_whenRealizableBelowMark`（出金 brick）
- `test_stress_governanceDetach_bricks_whenRealizableBelowMark`（detach brick）
- `test_stress_emergencyShutdown_survives_frozenWithdraw`（withdraw-revert には耐性＝働く valve）
- `test_stress_emergencyShutdown_bricks_whenTotalAssetsReverts`（totalAssets-revert で brick＝残存穴）

**保全策（＝ADR-007・要 SHIN 承認＋再監査）**：(a) 実現額を book し `received<mark` でも `activeAdapter:=address(0)` を許す **force-detach（try/catch）**、(b) Ethena に上限付きガバナンス slippage setter、(c) 該当 totalAssets 読取を try/catch 内へ＋Pendle oracle fallback、(d) Pendle totalAssets に保守 haircut。

### ② 【現状 low／解禁時 high・own_code＋future_adapter】離散収穫アダプターで JIT 復活
本体に構造的 JIT 防御ゼロ（`totalAssets` が activeAdapter を無平滑 pass-through）。報酬請求型アダプターを1つ whitelist した瞬間に JIT 復活。
**保全策**：Yearn 型 **locked-profit streaming**（実現益を N 時間で線形リリース）を本体に（ADR-007）。着地まで **「連続 accrual アダプターのみ whitelist 可」を運用 invariant** とする（下記【運用規約】）。

### ③ 【MEDIUM・own_code】手数料が相互作用時に未チェックポイント（配分公平性）
`collectFees` が単一 `_lastHarvestTimestamp` から全 elapsed を現プールに課金 → 後入 depositor が不在期間分まで希薄化／退出者が保留手数料を残存者へ転嫁／料率変更が遡及。principal 損失なし・上限 5%/yr×elapsed。
**PoC（在 repo・green）**：`test_collectFees_KNOWNISSUE_lateDepositorDilutedForPriorPeriod`（後入 Bob が保有0秒でも希薄化）＋`test_collectFees_permissionless_lowTVL_advancesAnchor_noMint`。
**保全策**：`_deposit`/`_withdraw`/`setManagementFee` 冒頭で crystallize＋`collectFees` に nonReentrant/CEI（ADR-007）。

### ④ 【MEDIUM・own_code / ops】Keeper 主導 DCA の一時カストディ（非カストディ未達）
permit/forwarder 不在で Keeper が `transferFrom(user→keeper)→deposit` する窓で product wallet が実際にユーザー資金を保有。
**保全策**：`depositWithPermit`／trusted-forwarder で user→vault を atomic 化・receiver=署名者固定（ADR-007）。**着地まで Keeper は treasury 入金限定・ユーザー DCA はフロント署名**（下記【運用規約】）。

### ⑤⑥ 【LOW】
移行時 NAV ステップ（評価方式差×48h）／Venus `exchangeRateStored` stale-rate deposit sandwich（**Venus 解禁前ブロッカー**）／Pendle `MIN_TWAP` 下限無し → `require(twapDuration_>=900)`／vault-triggered swap の bounded MEV（fair-value min-out・`MAX_SLIPPAGE_BPS<3%`・MEV 保護 relay 運用要件）／deploy スクリプトの governance=EOA デフォルト revert／`performanceFee` dead-code を not-implemented revert 化。

---

## 外部・受容（運用でのみ保全）

- **USDe/crvUSD デペグ**：Ethena exit が 0.5% 床を割れず revert（①の setter＋7日 cooldown fallback＋runbook で緩和・根は外部）。
- **Aave reserve pause / 利用率100%**：当該出金が一時停止／空きcash内の出金は成功・損失なし・自動復旧。
- **Pendle 満期前**：AMM 価格でのみ退出、TWAP 乖離で一時停止しうるが**満期で par 退出保証**。
- **Mass-exit バンクラン**：即時出金は製品設計上の受容、過払いは haircut 床で hard-cap。
- **Keeper 鍵漏洩（HIGH/external）**：立替 USDC 承認の一括ドレイン → **HSM/KMS 署名ポリシー＋無制限承認禁止＋per-cycle exact/permit**。

---

## 運用規約（今すぐ有効・コード改修不要）

1. **アダプター解禁ゲート**：profit-streaming（②）着地までは **連続 accrual アダプターのみ whitelist 可**。報酬請求型（離散収穫）アダプターは登録禁止。
2. **DCA Keeper**：Keeper 鍵に **sxUSDC / ユーザー資産の allowance を絶対に付与しない**。ユーザー DCA が permit 化されるまで Keeper は **treasury 入金のみ**。鍵は HSM/KMS・per-cycle exact 承認。
3. **swap 実行**：vault-triggered swap は fair-value 基準 min-out＋MEV 保護 relay 経由を必須運用とする。
4. **ガバナンス移行**：本番デプロイは governance/guardian/feeRecipient が単一 EOA のままなら実行しない（Timelock＋2-of-3 Safe 必須）。
5. **デペグ runbook**：Ethena/Pendle の exit 経路が床で revert した場合の手順（cooldown fallback・pause・段階退出）を運用手順書に保持。
