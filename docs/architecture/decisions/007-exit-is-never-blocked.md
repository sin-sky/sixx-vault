# ADR-007: 出口は止めない（Exit Is Never Blocked）— 4本柱

- **Status**: Accepted（SHIN 承認・2026-07-13）
- **Scope**: `SIXXVault`（ERC-4626 コア）と単一アクティブアダプター経由の資金退出
- **関連コードマーカー**: `ADR-007 #1`（`totalAssets()`/緊急弁の read 耐性・H-02）, `ADR-007 #2`（profit streaming・JIT 防御）, `ADR-007 #3`（変換前 fee crystallize）

## Context

Vault は idle を持たず、資金の大半を外部プロトコル（Aave / Venus / Ethena+Curve / Pendle）へ
単一アダプター経由でデプロイする。外部プロトコルは毀損・凍結・流動性枯渇・オラクル停止を起こしうる。
ユーザー資産の第一原則は **「いかなる状態でもユーザーは自分の持ち分を退出できる」**。
本 ADR はその原則を 4 本の柱として明文化し、各柱の実装状況を確定する。

## Decision — 4本柱

### 柱1: 退出経路は revert で塞がれない（read 耐性）
`totalAssets()` は毀損/未 ready なアダプター評価でも **revert しない**（try/catch → `_totalDebt` fallback, H-02）。
ERC-4626 の変換・preview・fee 徴収がすべて `totalAssets()` を読むため、評価の revert は全退出をブリックする。
緊急弁（`setEmergencyShutdown`）とアダプター切り離し（`setAdapter(address(0))`）も try/catch で、
壊れたアダプターが弁自体をブリックできない（`ADR-007 #1`）。
- **実装状況: 実装済（honest partial-fill・E1 検証済）。** `_recallFromAdapter` の all-or-revert は撤廃。
  `withdraw`/`redeem` は `_exitRealize` で自分の pro-rata スライスを best-effort recall し、**実受領デルタだけ**を
  払い出す（アダプター withdraw は try/catch で revert しても `fromAdapter=0` に縮退）。mark が過大なまま実配布が
  不足しても退出は**塞がれない**（E1 Case A で `stuck=0` を実測）。旧「realizable を超える請求で revert」リスクは解消。

### 柱2: 価格の公平（honest NAV）
全ユーザーの share は同一瞬間に同一価格で評価される。NAV は実残高由来（`balanceOf + adapter.totalAssets()`）で、
harvest 益は `PROFIT_UNLOCK_PERIOD` に線形 vest（JIT skim 防止・`ADR-007 #2`）、fee は変換前に crystallize
（遅参者を過去分で希薄化しない・`ADR-007 #3`）。**誰かだけ有利な価格で抜けることはない。**
- **実装状況: 実装済**（M-1 dilution・profit streaming・fee crystallize、Round 8 で B-1 PoC により shutdown 中も
  streaming 維持が正当と確認）。

### 柱3: 流動性の公平（先着が流動性を独占しない）
idle 流動性と部分的にしか引き出せないアダプター容量は、退出者間で **公平（pro-rata 相当）に配分**されるべきで、
先着が現金を総取りし後列を請求権だけに残す事態を避ける。
- **実装状況: 実装済（pro-rata 上限クランプ）。** `_exitRealize` は各退出者を **idle・adapter の自分の
  pro-rata スライス**にクランプする（`idle×shares/supply` + `mark×shares/supply` の実受領）。honest mark 下では
  全員フラット（E1 Case C/D）。**残余**: mark が持続的に過大な窓では先着有利が残るが、**e ≈ 2.72× で有界**
  （M-1・`007-prefreeze-measurements.md`）。真の防御は burn 価格ではなく **stale mark 検知 + force-detach**
  （`docs/operations/depeg-mark-staleness-runbook.md`）。SHIN 2026-07-13: burn は mark 価格を維持、realizable 価格は却下。

### 柱4: 恒久的な請求権（現金で払えない分はクレームとして残す）
即時に現金退出できないユーザーも、持ち分の **pro-rata 請求権**を失わず、後で回収できる（claim queue 等）。
最後に退出する人が **stuck**（請求権すら消える）してはならない。
- **実装状況: 実装済（residual ERC-20 share・キューなし）。** 部分約定時は払った現金分の share だけを burn
  （`sBurn = convertToShares(payout, Ceil)`、offered shares で cap）、**残余 share を保持**＝そのまま pro-rata 請求権。
  最後の人も **stuck しない**（E1 全 Case で `stuck=0`）。凍結→解凍で residual が同一 per-share 価値を運ぶ
  （D-3 実証）。新規 claim queue は不要（timing 均等が製品要件になった場合のみ別途起票）。

## Consequences

- 柱1〜柱4 すべて**実装済**（E1 で数値検証）。柱1（no revert）・柱2（honest NAV）・柱3（pro-rata クランプ）・
  柱4（residual share）。設計 (c)＝pro-rata 上限クランプ + residual-share を採用（claim queue なし）。
- **残存リスク（正典化）: stale-overstated-mark 窓の先着有利。** honest mark 下では skew=1.0（全員フラット）。
  mark が持続的に過大な窓でのみ先着有利が出るが、**overstate 率・idle 比率・N に依らず e ≈ 2.72× で有界**
  （M-1）。誰も stuck せず（柱1）、residual share は mark 訂正後に価値回復（柱4）。窓の**継続時間**は
  「depeg 深度 × 検知→force-detach レイテンシ」で有界（M-2）。SIXX の実マークで持続的過大が起き得るのは
  Ethena/Pendle の depeg のみ（Class P）で、Aave/Venus は流動性一過性（Class L・自己回復）。
- **この残余の防御は burn 価格層ではない。** realizable 価格 burn は却下（SHIN 2026-07-13）: 一時的流動性不足を
  永久損失に確定し、薄い recall を誘発する強制ライトダウン（新攻撃面 D-4#3）を作り、柱4 を壊す（R8-1 型の轍）。
  真の防御は **検知 + force-detach**（下記 runbook）。

## Follow-up

- **E1 測定: 完了。** 先着有利を数値化（Case A で skew を実測、Case C/D で honest markdown フラットを確認、
  全 Case で `stuck=0`）。柱3/4 実装状況を本 ADR に反映済。
- **M-1〜M-5 pre-freeze battery**（`docs/architecture/designs/007-prefreeze-measurements.md`）: 残余 skew の
  e 有界性（M-1）・実マーク写像（M-2）・残余正典化 + runbook（M-3・本節）・敵対的コード検査（M-4）・
  全バッテリー再走（M-5）。**全 green まで再凍結・タグ・束再生成・broadcast を禁止。**
- **運用防御: `docs/operations/depeg-mark-staleness-runbook.md`**（検知シグナル A/B/C・WARN/ACT 閾値・
  force-detach 手順・30 分レイテンシ予算）。ライブ監視の実装とガバナンス expedited detach 経路は ops-infra
  課題として同 runbook §5 に起票。
