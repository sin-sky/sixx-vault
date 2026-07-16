# PendlePTAdapter — recall-haircut 較正手順(activate 前必須)

> 対象: `src/adapters/PendlePTAdapter.sol`(escalate#1 / ARCH_RULING §3-4)。
> 目的: `recallHaircutBps` を **live のポジションサイズで実測したフル退出ラウンドトリップ以上**に較正し、
> フル recall / `setAdapter` 移行が構造的に成立(fail-close ではなく完了)する状態で activate する。
> この doc は Round-8 v2 独立レビュー(PR#2)の **マージ条件 (b)** = 「haircut 較正手順の文書化 + 3% cap が
> target AUM で十分かの検証」を満たす。**コントラクトは無改変**(テスト/doc のみ)。

---

## 1. なぜ haircut が要るか(不変条件)

満期前 PT は un-haircut TWAP mark を下回って realize する(市場インパクト + sUSDe→USDC 脚)。SIXXVault は
`_recallFromAdapter` で `received >= toWithdraw`、`setAdapter` で `received >= adapterBal`(M13-16 ガード)を強制するため、
un-haircut NAV だとフル回収・移行が **revert** していた。

escalate#1 の解:**報告 NAV と withdraw の end-to-end min-out を単一 `_navFloor` で一致させる**。

- `_navFloor(ptBal) = usdc( ptMark(TWAP,par-cap) × (1 − recallHaircutBps/10000) )`(`PendlePTAdapter.sol:492-501`)
- `totalAssets() = _navFloor(ptBal) + idle`(`:341-346`)
- `withdraw()` フル退出の `minUsdcOut = _navFloor(ptBal)`(`:376-380`)、sUSDe→USDC 脚が未達なら revert(`:414`)

→ 退出が**完了すれば** `received ≥ 報告NAV = adapterBal` が構造的に成立。市場が floor を満たせなければ
**revert(fail-close・資金移動なし)**。∴ haircut は「NAV を下げて余白を作る」のではなく、**NAV と floor を同時に下げて
ガードを恒真に保つ**装置。数値の正しさ(= haircut が実 slippage 以上か)が liveness を決める。

## 2. 較正ルール

```
recallHaircutBps  ≥  measured_full_exit_roundtrip_bps(position_size)
                  =  Pendle PT 売却の市場インパクト(ptBal 全量)
                   + sUSDe→USDC 脚(注入 IStableSwapper の Curve 経路)のインパクト
                   + TWAP-vs-spot クッション(TWAP mark と実約定 spot の乖離)
```

- **既定値** `recallHaircutBps = 50`(0.5%、`:218`)。**これは仮値**。activate 前に上記実測で上書きすること。
- **ハード上限** `MAX_RECALL_HAIRCUT_BPS = 300`(3%、`:83`)。governance が `setRecallHaircutBps`(`:568-575`, governance-only, cap 強制)で設定。
- **under-calibration の帰結**: haircut < 実 round-trip だと、**フル recall と `setAdapter` 移行が常時 fail-close**(revert)。
  ユーザーの部分退出も slice が floor 未達なら revert。資金は毀損しない(fail-close)が、**流動性(退出/移行)が凍る**まで
  ①市場タイト化、②haircut 引き上げ(≤3%)、③満期到達(par)を待つことになる。

## 3. 3% cap が target AUM で十分かの検証(必須)

`MAX_RECALL_HAIRCUT_BPS = 300` は**ハード上限**。もし target AUM のフルポジションを一度に売る際の
実 round-trip が 3% を超えるなら、**cap では吸収できず**、フル recall / 移行は cap を上げても fail-close のままになる
(コード上限の引き上げ = コード変更 → 要再監査)。

`test/PendlePTAdapterLoadedSlippageFork.t.sol::test_maxHaircut_stillFailsUnderDeepSlippage` が
この性質を実証している(3% haircut でも 25% インパクト市場ではフル redeem が fail-close)。

**運用要件(activate 前)**:
1. mainnet fork(pinned block)で **target AUM 相当のポジション**を組成し、フル退出を実行して
   `realized / mark` を実測 → `1 − realized/mark` が実 round-trip(bps)。
2. `recallHaircutBps` をその実測値**より少し上**に設定。
3. 実測が 3% を超える場合は、**ポジションサイズを bound**(deposit cap / 分割退出運用)するか、
   3% cap の妥当性を SHIN が判断(超えるなら cap 引き上げ=要コード変更+再監査、または当該サイズを不採用)。

## 4. by-design のトレードオフ(UX へ申し送り)

- **部分退出も個別に fail-close**(フルへのフォールバック無し)。市場ギャップ時は小口出金も revert し得る。
  UI は「一時的に出金不可(0 確定・持分は保持)」を明示し、`007-pro-rata-exit-design` / force-detach 導線に接続する。
- **緊急弁**: shutdown + 小口分割退出 + 満期 par 償還。governance の force-detach(`setAdapter(0)` best-effort)は
  vault 側の別ガードに従う(本 adapter の strict 移行とは別)。

## 5. 参照

- テスト(fail-close 実証): `test/PendlePTAdapterLoadedSlippageFork.t.sol`(control 成功 + フル/部分/移行/setAdapter(0) fail-close + 3% cap tie-in)。
- 既存の par-swapper 統合: `test/PendlePTAdapterVaultForkTest`(成功側=0 slippage)。
- 単体: `test/PendlePTAdapterUnit.t.sol`(`test_withdraw_fullExit_reverts_whenHaircutTooTight` 等)。
- 設計: escalate#1 コミット `674876a`、`docs/architecture/decisions/`(ADR-004 §4 mark = TWAP-only)。
