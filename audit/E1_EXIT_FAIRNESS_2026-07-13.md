# E1 — 取り付け時の先着有利の測定（ADR-007 柱3/柱4 ギャップ）

> **測定のみ。本番 src 無改変。** PoC = `test/ExitFairnessE1.t.sol`（`FaultInjectingAdapter` 使用）。
> 構造変更（pro-rata / claim queue）は本測定の結論が出るまで着手しない（R8-1 の教訓＝測らずに直すと新面に新バグ）。

## 1. 払い出し経路（src 精読で確定）

`SIXXVault._withdraw` → `_recallFromAdapter(assets)` → `super._withdraw`（`assets` を receiver へ転送＋burn）。

- **idle 先行**：`_recallFromAdapter` は `idle >= assets` なら **recall せず** idle から全額。不足時のみ `needed = assets - idle`。
- **recall は「必要額だけ」**（`needed`、アダプター mark `available=totalAssets()` で上限クランプ）。**pro-rata ではない。**（`SIXXVault.sol:349-366`）
- **返せないとき**：`require(received >= toWithdraw, "VAULT: adapter shortfall")` → **revert**（`SIXXVault.sol:372-375`）。
  - アダプターが **正直に mark を下げれば**（realizable=mark）、NAV が下がり `assets` も縮むため revert せず退出可（Case C/D）。
  - アダプターの **mark が過大なまま実配布が不足**（realizable<mark）だと **revert**（Case A/B/E の tail）。
- `maxWithdraw` は mark ベースで満額を返す（`SIXXVault.sol:239-242`）→ integrator/preview には不足が見えない。

### ★最重要の答え
> **現行コードは、アダプターが自身の mark より少なくしか返せないとき withdraw を revert する。**
> これは R8-2/Gap#3 とは独立に、**realizable<mark のケースで既存コードが柱1（出口は止めない）を破っている**。
> revert を回避できるのは「アダプターが正直に mark を下げる」か「ガバナンスが force-detach で writedown する」場合のみ。

## 2. 測定結果（idle=30% / adapter=70%・同一share 5人が順に全額退出・TVL=50,000 USDC）

| Case | シナリオ | 受取（退出順） | cash out | stuck | 判定 |
|---|---|---|---|---|---|
| **A** | 部分配布（deliverBps=50%・mark 不変） | **10,000 / 0 / 0 / 0 / 0** | 1 | **4** | 先着が idle を総取り。2番目以降 revert。first/last 比 = ∞ |
| **B** | 完全ブリック（withdraw revert） | **10,000 / 0 / 0 / 0 / 0** | 1 | **4** | idle に収まる先着のみ脱出、残り stuck |
| **C** | 正直な毀損（adapter を 50% 焼却＝mark も低下） | **6,500 ×5** | 5 | 0 | 全員 **同一価格**・全員 cash・stuck ゼロ（公平） |
| **D** | force-detach（部分）→ 退出 | **6,500 ×5** | 5 | 0 | writedown で mark を realizable へ→ Case C 同等の公平に変換 |
| **E** | shutdown 一斉退出（部分配布） | **10,000 / 10,000 / 10,000 / 0 / 0** | 3 | **2** | 緊急 recall で idle を上積み→前列は脱出、mark 未 writedown ゆえ tail は revert |

（数値は PoC ログ実測。USDC 6dp。）

## 3. 判定 — 柱ごと

- **柱1（出口は止めない）＝ 破れている（realizable<mark 時）**。Case A/B は 5人中 **4人 revert**、Case E は **2人 revert**。
  最優先の設計課題。原因＝ `_recallFromAdapter` の `require(received>=toWithdraw)` による all-or-revert。
- **柱2（価格の公平）＝ 満たされている**。honest markdown（C/D）では全員が厳密に同一価格（6,500）で退出。
  過大 mark（A/B/E）でも「価格」は名目上同一（mark 不変）だが、それは**実現不能な紙上の請求**＝真の不公平は価格でなく**流動性**。
- **柱3（流動性の公平）＝ ギャップ実在**。idle と部分容量は **pro-rata でなく先着**に配分される。Case A では先着が idle 15,000 のうち
  10,000 を総取りし、残 5,000 idle は redeem-all が revert するため **誰も取り出せず stranded**。
- **柱4（恒久請求権）＝ ギャップ実在**。stuck ユーザーは share（請求権）を保持するが、**pro-rata 部分すら現金化する手段が無い**
  （redeem は all-or-revert）。最後の人は **stuck**。force-detach（ガバナンス操作）を挟めば C 同等に救済されるが、
  それは自動ではなく、毀損〜操作の間は退出不能。

## 4. 先着有利は有意か → **YES（構造的）**

realizable<mark の局面で先着有利は**有意**（先頭満額 10,000・後列 0・比 ∞）。honest markdown では**発生しない**。
すなわちギャップは「アダプターが実力を過大 mark したまま部分毀損・薄流動性・凍結に陥る」現実的な局面で顕在化する。
柱3・柱4 は**設計課題として起票に値する**。

## 5. 設計変更の規模見積り（着手は別途承認後）

| 目標 | 変更 | 規模 |
|---|---|---|
| 柱1（never revert） | `_recallFromAdapter` を honest partial-fill 化（realizable だけ引き、実受領で会計・不足時 revert しない） | 中（ERC4626 withdraw 経路の override） |
| 柱3（流動性の公平） | idle+realizable を退出者間で pro-rata 配分 / 退出キュー | 大（コア会計に触れる） |
| 柱4（恒久請求権） | 請求時 NAV を固定した claim/withdrawal queue（後日回収） | 大（新規サブシステム） |

> **注意**：これらは相互に絡む（partial-fill を入れると share の burn 量・NAV 定義・先着順の意味がすべて変わる）。
> R8-1 同様、実装前に「新設計での取り付け」を PoC で再測定してから着手すること。

## 6. 現状の緩和（設計変更前の運用）

- 過大 mark のアダプターが部分毀損したら、ガバナンスが **`setAdapter(address(0))`（force-detach）で honest writedown** →
  Case D のとおり全員 pro-rata・stuck ゼロに収束。ただし**手動**であり、操作までの窓では退出 revert。
- 部分退出（`withdraw(assets)` で `assets<=idle`）は idle 内なら成功するため、stuck ユーザーは残余 idle を手動で分割回収し得るが、
  これは **先着競争**であり公平でない（柱3 の裏返し）。

> **収束していない。** 本測定は柱3/4 ギャップの実在を数値で確定したのみ。設計変更は未着手（承認待ち）。fork 面（B-3）も未了。
