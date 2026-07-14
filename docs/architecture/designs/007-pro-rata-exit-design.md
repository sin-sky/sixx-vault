# 設計書: pro-rata 退出（ADR-007 柱1+柱3+柱4 の融合実装）— GO/NO-GO レビュー用

> **Status: DRAFT（SHIN レビュー待ち・GO 前は本番 src 無改変）**
> 測定根拠: `test/ExitFairnessE1.t.sol`（E1・現状）/ `test/ExitFairnessDesignD2.t.sol`（D-2・3設計比較 + 柱4）。
> 前提モデル: idle=30%・adapter mark=70%・realizable=mark の 50%（薄流動性/stale mark）・同一 share 5人が順に退出。

---

## D-1 — 柱1 を単独で「idle 先行フル」実装しない（柱1+柱3 融合設計）

E1 と D-2(b) が示すとおり、**「idle 先行フル + revert 撤廃」だけでは先着総取りが温存**される（先頭満額・後列ゼロ）。
正しい設計は **全退出（先頭を含む）を「現在の realizable NAV に対する持ち分 pro-rata」に上限クランプ**する。

### アルゴリズム（融合設計 = D-2(c)）

`redeem(shares)` / `withdraw(assets)` 共通:

1. `_collectFees()`（既存・変換前 crystallize）。
2. **realizable NAV** を確定: `realNAV = idleBalance + recallableFromAdapter`。
   - `recallableFromAdapter` は **honest partial-fill で実測**（mark を信用しない）：必要分を best-effort recall し、
     実受領デルタを使う。mark 過大（realizable<mark）でも realNAV は実力を反映する。
   - locked-profit は既存どおり控除（`totalAssets()` は `raw - lockedProfit()`）— 部分退出が未 vest 益を skim しない（B-1 教訓）。
3. **pro-rata 上限**: `entitled = shares × realNAV / totalSupply`。ユーザー要求額 `assets` は `min(assets, entitled)` にクランプ。**先頭にも適用。**
4. **払い出し**: `pay = min(entitled, 現在の流動性(idle + 今回 recall 実受領))`。idle 先行、不足は adapter recall。
5. **share burn**: `burn = shares × pay / entitled`（`pay==entitled` なら全 burn）。**revert しない**（柱1）。
6. **residual**: `shares - burn` を **保持**（＝柱4 の請求権、後述 D-3）。

### なぜ先頭クランプが要るか（D-2 数値）

| 設計 | 受取（退出順・USDC） | cash | 0受取 | 全員均等? | 柱1 | 柱3 |
|---|---|---:|---:|:--:|:--:|:--:|
| (a) 現状: idle先行・必要額recall・all-or-revert | **10000/10000/10000/0/0** | 3 | 2(revert) | ✗ | ✗ | ✗ |
| (a') 現状 + ガバナンス force-detach（socialization） | 6500×5 | 5 | 0 | ✓ | 手動 | ~手動 |
| (b) 柱1のみ: idle先行フル・honest partial | **10000/10000/10000/2500/0** | 4 | 1 | ✗ | ✓ | ✗ |
| **(c) 柱1+柱3融合: pro-rata 上限クランプ** | **6500×5** | 5 | 0 | ✓ | ✓ | ✓ |

→ **(c) のみが 柱1(no revert)・柱2(全員同一 6500)・柱3(先着独占なし) を同時達成**。しかも **自動**（ガバナンス force-detach 不要）。

---

## D-2 — 3設計の同一シナリオ再測定（実装前）

上表のとおり `test_D2_compareThreeDesigns` で数値確定（すべて PoC ログ実測）:

- **(a)** 先頭3人が face 満額を取り、tail 2人は `require(received>=toWithdraw)` で **revert**＝stuck。first/last 比 = ∞。
- **(b)** revert は消えるが **先着温存**（10000 vs 0）。柱3 未達。
- **(c)** 全員 **6500**（realizable NAV 32,500 ÷ 5）。均等・全員 cash・stuck 0。

**結論: (c) が最善**。R8-1 の教訓（実装前に新設計で取り付けを測る）に従い、数値で確認済み。

---

## D-3 — 柱4 は新規サブシステム無しで満たせるか → **原則 YES（residual ERC-20 share）**

**「pro-rata で払った share だけ burn、残り share は保持」= 残余 ERC-20 share がそのまま請求権**。新しい claim/queue は原則不要。

### 根拠（`test_D2_pillar4_residualSharesCarryValue_noQueue`・凍結→解凍2パス）

adapter 分が pass1 で凍結（idle のみ liquid）、pass2 で解凍:

| | pass1 cash | pass2 で residual 償還 | **TOTAL value** |
|---|---:|---:|---:|
| user1 | 2000 | 0 | **2000** |
| user2 | 2000 | 0 | **2000** |
| user3 | 1000 | 1000 | **2000** |
| user4 | 0 | 2000 | **2000** |
| user5 | 0 | 2000 | **2000** |

→ pass1 の **cash は先着**だが、**最終価値は全員 2000 で均等**。residual share が同一 per-share 価値で価値を運ぶ。
share を realizable 価格で burn する限り、残余 share は後の回復時に公平に償還される＝**キュー不要**。

### キューが本当に要るケース（過剰設計を避ける）

- **「liquid-now < 総 entitlement」局面で cash の timing まで順序非依存に均等化したい**場合のみ、バッチ/請求キューが要る
  （同一窓の請求者に entitlement の同一比率を配る）。
- residual-share 方式では **価値は公平**・**revert しない**・**per-share 価格は常に均等**で、残る不公平は **cash 化の timing のみ**
  （早い人が先に現金、遅い人は満額の請求権を保持）。これは価値の窃取ではない。
- **推奨: キューは作らない**。timing 均等が製品要件（例: 規制/UX）であると SHIN が判断した場合にのみ、
  バッチ withdrawal queue を別途起票する。NAV 固定型キューは逆に「遅参者にリスク移転」しうるため慎重に。

---

## D-4 — 新設計の攻撃面（自己列挙・R8-1 教訓）

| # | 攻撃/懸念 | 対策 / 残リスク |
|---|---|---|
| 1 | **分母 `totalSupply` 操作**（退出直前に mint して希薄化） | deposit は資産と share を比例追加＝per-share realizable 不変。shutdown/pause 中は deposit 遮断。1 tx 内は supply 固定。**対策済** |
| 2 | **realizable の flash 操作**（外部プロトコルを flash-lend で一時的に厚くして多く引く） | `entitled` は **自分の share の pro-rata に上限**＝一時的に realizable が膨らんでも自分の取り分以上は取れない。flash で膨らんだ分は次以降の realNAV に反映され全員に均霑。**残リスク: 低**（自分の pro-rata が上限） |
| 3 | **作為的 shortfall 誘発**（recall を意図的に薄くして後続を stuck） | (c) は stuck しない（honest partial + residual）。薄い局面でも各自 pro-rata + 残余 share。**対策済** |
| 4 | **部分 burn と fee/locked-profit の順序依存** | 順序を固定: `_collectFees` → realNAV 算定（`lockedProfit` 控除後）→ クランプ → recall → pay → burn。locked-profit 控除後 NAV でクランプするため部分退出が未 vest 益を skim しない（B-1）。**要実装テスト**（順序回帰） |
| 5 | **「残った share」が次退出者を希薄化しないか** | residual share は残余資産への比例請求＝希薄化しない（D-3 で TOTAL 均等を実証）。burn は `shares×pay/entitled`（realizable 価格）で丸めは **protocol 有利に ceil**（ERC4626 withdraw 準拠）。**対策済**（丸め方向を固定） |
| 6 | **ERC-4626 準拠**: `maxWithdraw`/`previewRedeem` が realizable を反映するか | `maxWithdraw = min(convertToAssets(shares), pro-rata realizable)` に変更、`previewRedeem` は同クランプ値。integrator は mark 過大で驚かない。**残リスク（要 SHIN 判断）**: realizable を厳密に事前算定できない場合（recall しないと分からない）、preview は **上限見積り**となり ERC4626 の「preview は実額と一致」を厳密には満たさない局面がある。緩和案: preview は mark ベース上限を返し、実額は realizable にクランプ＝preview ≥ 実額（over-promise しない側に倒す）。**要仕様確定** |
| 7 | **realizable 測定コスト/再入**（recall を preview で走らせられない） | preview は view であり recall（状態変更）を伴えない。→ #6 の緩和（mark ベース上限 preview）を採用。実 recall は nonReentrant な redeem/withdraw 内のみ。**対策済**（再入は既存 guard） |

---

## GO/NO-GO 判断材料（SHIN レビュー）

- **推奨: (c) 柱1+柱3 融合 pro-rata 上限クランプ + residual-share 柱4（キューなし）を採用。**
  数値で (c) が 柱1/2/3 を同時最善、柱4 を新規サブシステム無しで達成（D-2/D-3）。
- **未確定で SHIN 判断が要る点**:
  1. **#6 ERC-4626 preview の厳密一致**（realizable を事前算定できない→ preview を上限見積りにする緩和で妥協するか）。
  2. **timing 均等（キュー）を製品要件とするか**（不要なら residual-share のみ＝実装小）。
  3. **A6 と同様の手数料**: 部分退出時の fee 順序（#4）確定。
- **実装規模**（GO 後）: 柱1+柱3 融合 = `_recallFromAdapter`/`_withdraw`/`maxWithdraw`/`previewRedeem` の改修＝**中**。
  柱4 = residual-share なら **追加ほぼゼロ**（burn 量を pay/entitled にするだけ）。キュー採用なら **大**。
- **GO 後の必須**: 本 PoC の (c) を**本番実装で再測定**（取り付け・部分・shutdown・honest損・flash 操作）してから凍結。

> **収束していない。** 本書は設計案 + 実装前測定。GO 前に本番 src は触らない。B-3（fork）も未了。

---

## D-5 — Round-8 v2 独立監査(6エージェント)で確定した残余 / 将来の罠

独立監査(A〜E、src+test のみ・過去論拠非開示)＋裁定 F。収束した Medium 1件＋Low を記録。

### C-1 / D-1 / E-1(収束・Medium・解決済み)— 先着 skew は「bounded by e」ではない
`ExitSkewM1` の「skew < e」は **mock の線形 delivery(`deliverBps`)の産物**であり、実システムの性質ではない。
- **convex アダプター**(実 Curve/Ethena:深さ枯渇まで ~100% fill → 崖):skew **6.08×**(`ExitFairnessProdC` 実測)。
- **valuation revert × 実損**:stale `_totalDebt`(実損で減算されない)に fallback → NAV 過大報告 →
  先頭退出者が realizable を全取り、最後は 0 = **skew ∞**(`ExitSkewRevertFallbackC` 実測)。
- **solvency は保持**(価値創造なし、Agent B が 2M-iter+20試行で確認)。**唯一の囲いは governance force-detach**
  (`_totalDebt` を realized に書き落とし → 公平 pro-rata。`test_C_forceDetach_restoresFairness` で実証)。
- **解決**:(1) 偽有界性を全 doc/コメントで訂正(本節・`007-prefreeze-measurements` §M-1・runbook・ExitSkewM1/E1)、
  回帰テスト `ExitSkewRevertFallbackC` 着地、runbook に「**valuation revert 検知 → 即時 force-detach**」を義務化。
  (2) 柱1保存の最小コードガード(valuation 不読 → force-detach まで idle-only)は敵対的検査後に採否判断。

### F-A1 / E-2(収束・Low・将来の罠)— last-holder exit の locked-profit strand
上記 CLAUDE.md「Discrete-harvest adapters」チェックリスト参照。現行は全 adapter no-op harvest ゆえ到達不能。
discrete-harvest アダプター追加時に `_lockedProfit` strand + JIT を必ず再検証すること(恒久ルール)。

---

## D-6 — Round-8 v2 独立監査(6エージェント @ b835c09)の裁定 F と C-1 ガード自体の残欠修正

独立監査(src+test のみ・過去論拠非開示・6エージェント)は **C-1 ガード commit(b835c09)自体に新規 Medium を1件**発見し
4 finder が独立収束(F が wei 単位 PoC)。**raw 7 findings のうち新規は実質1件**、残り6件は既記録の
C-1/D-1/E-1(収束・上節)・F-A1/E-2(locked-profit strand・上節)の重複 or 論拠済みで**却下/未確定**
(各 raw finding の逐条根拠は監査ラン `wvzx41sq0` の出力に残す)。

### F(新規・収束・Medium・**修正済み**)— idle-only 分岐の loss-blind burn 価格による先着 skim
C-1 ガードは valuation 不読時に `_exitRealize` を idle-only(recall しない)にしたが、**部分フィルの share 焼却が
`sBurn = _convertToShares(payout)` のまま**で、`totalAssets()` は revert 時 loss-blind な `_totalDebt` に degrade
= **過大 NAV(mark)で焼く**。ゆえに idle>0 の窓で先着 exiter が share を**過少焼却**し過大 residual を保持 →
force-detach 後に非公平取り分。対称2ホルダーで **alice 4735.96 / bob 4264.04(fair 各 4500、skim 471.9 ≈ 10.5%)**
= ADR-007 **柱4(realizable 価格で burn し per-share を保つ)違反**、F-1 型の再発。回帰テスト
`ExitSkewRevertFallbackC` が idle==0 でしか公平性を主張しておらず(0/0 で自明成立)見逃していた。

- **なぜ mark でも idle-only 価格でも駄目か**: revert 中は adapter の realizable `R` が**不可知**。per-share 保存は
  `sBurn = payout × supply / realNAV` を要求し、公平解の分母は `realNAV = idle + R` のみ。mark(=idle+`_totalDebt`)は
  過大 → 過少焼却 → **skim**。idle-only 価格(=idle)は過小 → 全焼却 → residual 0 → R が virtual share に stranded
  = **F-1 型 haircut(NO-GO)**。R 不可知ゆえ**部分 idle payout を公平に価格付けできない**。
- **修正(最小・設計忠実・新機構なし)**: valuation 不読 かつ 非 shutdown の still-attached アダプターでは
  `_exitRealize` が **payout=0・sBurn=0 を返し全請求権を保持**(`SIXXVault.sol` の "F guard")。柱1(brick しない=revert せず
  claim 保持)を満たしつつ、adapter の realizable は **force-detach で順序非依存に公平解放**。これは既存 idle==0 ガード挙動
  (both get 0)の idle>0 への忠実な一般化。**shutdown は除外**(recall 済で `_totalDebt=0` ⇒ mark=idle=正確 ⇒ skim 不能、
  かつ H-02 の緊急バルブを再 brick しない)。
- **挙動変更**: C-1 commit が謳った「idle still pays」を撤回。通常運用は idle≈0(non-custody・no-idle)ゆえ liveness 実損ほぼ無し、
  idle>0 時のみ発生していた skim を除去。broken-oracle exit は従来どおり force-detach-gated。
- **実証(wei 単位)**: `test/ExitSkewIdleOnlyBurnPriceF.t.sol`(修正後 alice=bob=4500、skim 0・haircut 0・9k 全額分配)、
  `ExitSkewRevertFallbackC::test_C_revertFallback_guard_idlePositive_noBurnPriceSkim`(idle>0 で 7000/7000)。
  ガードへの targeted mutation(shutdown 除外削除 / `&&`→`||` / catch 無力化)は**全 kill**。非-fork 323/0、healthy 経路 1-wei 不変。

### 柱4 の記述とコードの整合(D-3 の "realizable 価格で burn" の正確化)
D-3 の「share を realizable 価格で burn する限り公平」は、コードでは `sBurn = _convertToShares(payout)` = `totalAssets()`
基準の焼却として実装される。**valuation が readable なら `totalAssets()` は真の realizable NAV(idle + adapter 実測 − lockedProfit)
に等しく、mark==realizable ゆえ柱4 は成立**。ズレは **valuation 不読窓のみ**(mark≠realizable)で生じ、上記 F guard が
その窓で「非 realizable な mark で焼く」代わりに **0 焼却(0 payout)**とすることで解消した。よって柱4「burn は realizable 価格」は
**全到達経路で成立**(readable=realizable 価格で焼く / unreadable=価格付け不能ゆえ焼かない)。
