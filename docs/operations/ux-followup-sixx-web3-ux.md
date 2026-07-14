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

---

### 参照
- 台帳: `audit/ROUND8V2_INDEPENDENT_AUDIT_ADJUDICATION.md`(全 7 finding + 裁定 + ① 非誘発性)
- 設計: `docs/architecture/designs/007-pro-rata-exit-design.md` D-5/D-6、`docs/operations/depeg-mark-staleness-runbook.md`
