# UI 正典編集指示 → `sixx-interface: threads/design_ux/PRODUCT_UI_MASTER_SPEC.md`

> 出所: SHIN 訂正 2026-07-16(USDY NO-GO → RWA/米国債枠は Sky sUSDS)。**この repo(sixx-vault)からは
> sixx-interface に write できない(403)ため、本ファイルは適用指示のハンドオフ**。sixx-interface の
> codespace(または権限のある環境)で `PRODUCT_UI_MASTER_SPEC.md` に以下3点を反映して push すること。
> 根拠(vault 側)= `memory/decisions.md` item5(USDY 不採用 / sUSDS = (A) USDS 建て直挿し)。

## 編集1 — ①貯めるテーブル:「米ドル国債（USDY）」行を差替
旧「米ドル国債（USDY）」行 → 次の行に置換(SHIN 指定):

```
| 米国債・RWA運用（Sky sUSDS） | USDS/sUSDS | 年3〜5%・変動 | 1/5 | 即時（cooldown無・LitePSM1:1） | Sky sUSDS | 採用候補・+0.8%レートゲート待ち＝準備中 | ○ |
```

(列は既存テーブルのヘッダに合わせること。protocol/chain はカード非表示・詳細の provider 開示のみ、の既存方針を維持。)

## 編集2 — v1確定セット:「米ドル国債 USDY」を差替+注記
- 「米ドル国債 USDY」→ **「米国債・RWA（sUSDS・レート待ち＝準備中）」**
- 直後に注記を追加:
  > USDYは不採用（allowlist/KYC/Reg-S・2026-07-10 NO-GO）
- ※日付整合の確認: vault 側 `decisions.md` は USDY 不採用の**確定を 2026-07-16** と記録(設計スカウティングで allowlist/Reg-S ブロッカーを確認した日)。SHIN 指定の注記は「2026-07-10 NO-GO」。同一なら 07-10 を初期 NO-GO 判断日として維持、別イベントなら両日付を併記推奨。**どちらを正とするか要確認**。

## 編集3 — 開示文テンプレ・訴求コピー例:USDY→sUSDS
USDY 前提の文言を sUSDS 前提へ差替。sUSDS の性質に即した開示(禁止用語ゼロ・GLOSSARY 上位を維持):
- **裏付け**: 合成ドルではない。USDS(Sky の stablecoin)を Sky Savings Rate(SSR)で運用する ERC-4626 貯蓄トークン。
- **利回り**: 年3〜5%・**変動**(SSR は Sky ガバナンスで可変)。**利回り固定でも元本保証でもない**。
- **退出**: 即時(cooldown 無)。USDC↔USDS は LitePSM 1:1(入口 zap)。
- **リスク種別タグ**: 仕組み・デペッグ(USDS デペッグ)/ プロトコル(Sky)。価格変動は小(米国債・RWA 裏付け)。
- **採用基準欄**: リスク 1/5・信用度 ≥8(Sky/MakerDAO 系の実績)。**現状=準備中(+0.8% レートゲート未達)ゆえ数値・入金導線は伏せる**。
- USDY 固有の訴求(米国債直接・Ondo 等)は削除。「Reg-S/KYC 不要・非カストディで即時」を sUSDS の利点として訴求可。

## 適用後の確認(sixx-interface 側 CI)
- terminology-guard ハード FAIL 0(禁止用語ゼロ)。
- 準備中ゲート: sUSDS 行は live:false → 数値・入金導線を伏せる表示になっていること(Ethena と同じゲート)。
- custody/mobile/i18n PASS・build 緑・draft PR・PROGRESS 更新。

## vault 側の対応状況(参考)
sUSDS = USDS 建ての新 `SIXXVault` + 既存汎用 `ERC4626Adapter`(target=sUSDS)直挿し・**新規コントラクトコードなし**・即時退出。ビルド/デプロイは +0.8% レートゲート達成時・今回監査スコープ(core4+Ethena+Pendle)外。詳細 = `memory/decisions.md` item5。
