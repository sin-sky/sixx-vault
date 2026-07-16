# UX follow-up 起票 → `sixx-web3-ux`(vault 側は非ブロッカー)

> 出所: Round-8 v2 裁定 F(idle-only burn-price skim)修正 `06e13c9` の SHIN 受理条件③。
> vault コントラクトは修正済・凍結候補。以下は **frontend/UX 側の表示・導線**の follow-up。凍結ブロッカーではない。
> 起票先 workspace: `sixx-web3-ux`(本 repo に remote/issue tracker が無いため、本ファイルをハンドオフ記録とする)。

---

## UX-1(New)— 「引き出しても何も起きない」= valuation 不読時の idle-only 0-realize を明示せよ

**背景(コントラクト挙動、by design)**: adapter の `totalAssets()` が **revert(valuation unreadable = 実際の外部プロトコル障害・
Pendle TWAP not-ready 等)** している間、`withdraw`/`redeem` は **revert せず** に **payout=0・share を焼かず(claim 保持)** で返る
(F guard、`SIXXVault._exitRealize`)。これは skim=0・haircut=0・柱1 保存の設計解で、資金は governance force-detach で公平回収される。

**UX 要件**:
- frontend は redeem/withdraw が **0 を返す状態を「取引完了」と表示してはならない**。「一時的に 0 で確定/持分は保持・
  ガバナンスの流動性再アタッチ後に回収可能」と明示。
- 検知シグナル:`activeAdapter != 0` かつ `maxDeposit(user) == 0`(F guard 由来の deposit pause と同条件で valuation 不読)。
  = 「引き出し一時停止(0 確定)」バナー + 送信前の確認ダイアログ。
- `previewRedeem`/`previewWithdraw` は **mark ベースの上限見積り**を返し、この窓では**実受領 0** になり得る(preview ≥ 実額)。
  「見積りは上限・実受領は 0〜見積り」を注記(over-promise しない)。
- shutdown 時は idle 払い出しが**通常どおり効く**(F guard 除外)ので、この 0-realize 表示は **非 shutdown × valuation 不読**に限定。

## UX-2(既存 follow-up の再掲)— 大口 exit の部分/0 受領 + size-cap ガイダンス

**背景**: readable-but-overstated(phantom)mark / convex adapter の深さ枯渇では、大口 exit が preview 未満(最悪 0)を
受領し得る(KNOWN_MITIGATED 残余、force-detach-gated。裁定 F の #2/#6/#7)。既に「size-cap は UX follow-up」として deferred。

**UX 要件**:
- 大口 redeem に「見積り未満/一時 0 の可能性・持分は claim として保持」表示。
- 推奨 exit サイズ(size-cap)ガイダンス = 別途 size-cap 設計と併せて起票(NAV 固定キューは遅参者にリスク移転しうるため非推奨、
  `007-pro-rata-exit-design.md` D-3 参照)。

## BE-1 / UX-3(New)— 積立スキップ通知(残高/allowance 不足で見送られた回をユーザーに知らせる)

**出所**: `feat/dca-scheduler`(`src/periphery/DCAScheduler.sol`、未マージ・凍結対象外)の読み取り確認。
vault 本体・凍結 src は無関係。バックエンドが `ExecutionSkipped` を監視して通知する設計の前提整理。

**コントラクト挙動(現物)**:
- スキップは `executeBatch` の try/catch(254–255行)が捕捉し `event ExecutionSkipped(uint256 indexed planId, bytes reason)`(122行)を emit。
  失敗回の状態(`nextRun`/`totalPulled`)は**巻き戻る**ので `nextRun` は**前進しない**=プランは due のまま次バッチで再試行される。
- **単発 `execute()`(236–240)は try/catch 無し** → スキップ=tx 全体 revert で**イベントを出さない**。∴ 通知パイプラインは
  **keeper が `executeBatch` を使うこと**に依存する(単発運用だと skip が観測できない)。← keeper 運用要件として固定。
- 連続失敗に対するコントラクト側の自動措置は**無い**(失敗カウンタ/自動解約/自動 pause なし。`isDue` は allowance/残高を見ない 330行)。
  → 連続回数は**バックエンドが自前で集計**する。取りやめの実行はユーザー(非カストディ)。

**`ExecutionSkipped` に実際に乗るフィールド(通知文面の材料)**:
| 欲しい情報 | イベントに乗るか | 取得方法 |
|---|---|---|
| ユーザー特定(owner) | ✗(直接は無い) | `planId`(indexed)→ `plans(planId).owner`(71行)or `PlanCreated.owner`(indexed, 102行)と join |
| 失敗理由(残高不足 / allowance 不足の区別) | △(生 revert バイトのみ) | `reason` を**バックエンドがデコード**。SafeERC20 が原因を握り潰さず bubble(188–192行)。USDC=`"...exceeds balance"`/`"...exceeds allowance"`、OZ v5=`ERC20InsufficientBalance`/`ERC20InsufficientAllowance`。**トークン実装依存**かつ良性スキップ(`"DCA: not due"`等)と同じ `reason` に混在 |
| timestamp | ✗ | log の block(番号/timestamp)から |

**バックエンド要件(BE-1)**:
- `ExecutionSkipped` を購読 → `planId` で owner を解決(`plans()` or `PlanCreated` キャッシュ)。
- `reason` を分類:**残高不足 / allowance 不足 → ユーザー向け通知**。良性スキップ(not due / cap reached / expired / inactive=cancel 済)は**失敗ではない → 通知抑制**。分類器はトークン別(USDC 文字列 / OZ custom-error selector)に用意。
- 連続スキップ回数を owner×planId 単位で自前集計(コントラクトに無い)。1回=軽通知、連続=導線提示のトリガに使う。

**UX 要件(UX-3)**:
- 1回スキップ=軽い通知「今回の積立は残高不足で見送られました」。※文面注記: `nextRun` は前進しないため、**入金すれば次の keeper 実行で再試行される**(「次回は◯日」= その周期の nextRun ではなく次バッチ再試行になり得る点に注意。over-promise しない)。
- 連続スキップ=「入金する / 積立を一時停止する(`cancelPlan` or token 側 `approve(scheduler,0)`)/ プランを見直す」の選択肢。**自動解約はしない**(非カストディ・取りやめはユーザー主権 223行 / 24行コメント)。

**将来のコントラクト改修候補(今回の凍結に含めない・別タグでの改修)**:
- `ExecutionSkipped` に **owner を indexed で直載せ**(join 不要化)、および **構造化した理由コード(enum: InsufficientBalance / InsufficientAllowance / NotDue / CapReached / Expired / Other)** を追加すると、トークン別デコーダ無しで決定的に文面を出せる。timestamp は block から取れるため優先度低。
  → **現凍結には含めず**、`feat/dca-scheduler` 側の改修 backlog として記録(別タグ)。

---

### 参照
- 台帳: `audit/ROUND8V2_INDEPENDENT_AUDIT_ADJUDICATION.md`(全 7 finding + 裁定 + ① 非誘発性)
- 設計: `docs/architecture/designs/007-pro-rata-exit-design.md` D-5/D-6、`docs/operations/depeg-mark-staleness-runbook.md`
