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
- **実装状況: 実装済（read 耐性）。ただし「realizable を超える請求」の扱いは honest mark 前提** ―― `_recallFromAdapter`
  はアダプターが mark より少なく返すと `require(received >= toWithdraw)` で **revert** する。アダプターが正直に mark を
  下げれば NAV が下がり退出は成功するが、mark が過大なまま実配布が不足するケースでは退出が塞がれ得る。**要 E1 検証**。

### 柱2: 価格の公平（honest NAV）
全ユーザーの share は同一瞬間に同一価格で評価される。NAV は実残高由来（`balanceOf + adapter.totalAssets()`）で、
harvest 益は `PROFIT_UNLOCK_PERIOD` に線形 vest（JIT skim 防止・`ADR-007 #2`）、fee は変換前に crystallize
（遅参者を過去分で希薄化しない・`ADR-007 #3`）。**誰かだけ有利な価格で抜けることはない。**
- **実装状況: 実装済**（M-1 dilution・profit streaming・fee crystallize、Round 8 で B-1 PoC により shutdown 中も
  streaming 維持が正当と確認）。

### 柱3: 流動性の公平（先着が流動性を独占しない）
idle 流動性と部分的にしか引き出せないアダプター容量は、退出者間で **公平（pro-rata 相当）に配分**されるべきで、
先着が現金を総取りし後列を請求権だけに残す事態を避ける。
- **実装状況: 要検証。** 現行 `_recallFromAdapter` は **idle 先行 + 必要額だけ recall（pro-rata ではない）**。
  先着有利が構造的に発生するか否かを **E1 で数値測定**してから判断する（測る前に直さない）。

### 柱4: 恒久的な請求権（現金で払えない分はクレームとして残す）
即時に現金退出できないユーザーも、持ち分の **pro-rata 請求権**を失わず、後で回収できる（claim queue 等）。
最後に退出する人が **stuck**（請求権すら消える）してはならない。
- **実装状況: 要検証（未実装の可能性が高い）。** 現行は不足時 revert で、クレームとして残す仕組みは無い。
  **E1 で「最後の人はどうなるか（出られる/請求権が残る/stuck）」を測定**する。

## Consequences

- 柱1・柱2 は実装済だが、**柱1 は honest mark を前提**とし、mark 過大時の revert リスクを内包する（柱3/4 と連動）。
- 柱3・柱4 のギャップが E1 で **有意**と示されれば、pro-rata recall / claim queue を設計課題として起票する。
  **構造変更は E1 の測定結果が出るまで着手しない**（測らずに直すと R8-1 の轍＝新しい面に新しいバグを作る）。
- 本 ADR は現状の明文化であり、柱3/4 の実装可否・規模は E1 の数値に基づいて別途決定する。

## Follow-up

- **E1 測定**（本 ADR と同時進行）: 取り付け時の先着有利を数値化。払い出し経路の確定、
  「返せないとき revert するか」の確定、先着1番目 vs N番目の受取比率、現金で帰れた人数、
  価格公平/流動性公平の分離、force-detach・partial・shutdown 各ケースでの最後の人の帰結。
- 結果は `audit/` に記録し、本 ADR の柱3/4 実装状況を更新する。
