# 複数アダプター × 障害 相互作用監査 — 実施記録（正典）

> 区分: 🟢 done。2026-07-12。Part A（本番 src 無改変・凍結 `2e8f059`／test・mock・doc のみ）。
> 対象: 複数アダプターが関わる状態面での資金保護インバリアント（MINV-1〜6 ＋ 既存 INV-1〜9）。
> 二エンジン（Foundry invariant ＋ Echidna）。設計元＝`threads/code_audit/MULTI_ADAPTER_FAULT.md`。

---

## 0. アーキ確定（実 src 判定・最重要）

`src/core/SIXXVault.sol` / `AdapterRegistry.sol` / `src/adapters/*` を読んで確定：

| 論点 | 判定（src 根拠） |
|---|---|
| 同時に資金を置く adapter 数 | **単数**。`address public override activeAdapter;`（L49）。資金は「active 1個 or idle」のみ。**⇒ model (A) 単一 active・移行モデル** |
| 移行 A→B の残余 | **健全移行は全額 recall（strict）**：migration 分岐は `adapterBal = A.totalAssets(); A.withdraw(adapterBal); require(received >= adapterBal)`（L452-463）。**健全移行後の旧 adapter 残余＝ゼロ**（不足なら migration が revert） |
| force-detach A→0 | **best-effort**（L411）。lossy/frozen 時は残余を旧 adapter に stranded（NAV から write-off）。**再接続で回収可能** |
| 退役 adapter の資金/呼出 | 退役（detach/非 active）adapter は **dormant**。state-changing entry は `onlyVault`、vault は **active しか呼ばない**。stranded 資金は再接続で回収 |
| registry の複数 vault 共有 | registry は **トークンロジックなし**（whitelist のみ・`grep transfer/balanceOf` → 0）。資金は各 vault 保有。**cross-vault 資金汚染は構造的に不能** |
| rescueToken/harvest の越境 | 各 adapter の rescueToken は `IERC20(token).balanceOf(address(this))`（自分の残高のみ）。**別 adapter のトークンに触れない**。harvest も per-adapter |

### → 実装面の帰結

- **(A) 系（MA1-MA4）＋ 共通（MR）を実装**。
- **(B) 複数 concurrent（MB1-MB4）＝構造的に発生しない**：vault は同時に 1 adapter しか資金を持たない（`activeAdapter` 単数・移行時は全額 recall）。資金分散が起きないため「クロス adapter 隔離（並存）」「集約 solvency（並存）」「部分退出（並存）」は非該当。**移行の逐次性における残余非干渉（MINV-5）とクロス隔離（MINV-1）は (A) の形で実装**。

---

## 実装物（Part A・src 無改変）

| ファイル | 役割 |
|---|---|
| `test/invariant/MultiAdapterFault.t.sol` | model A の MINV invariant（no-phantom・aggregate solvency・registry 整合）＋ 決定論チェーン MA1-MA4。`StateTransitionHandler`（4-adapter プール・migrate/detach/reattach × per-adapter fault）を再利用して fuzz breadth を確保 |
| `test/echidna/StateTransitionEchidna.sol` | 別エンジンに `echidna_no_phantom_cross_adapter` を追加（3-adapter プール移行 × 障害下で detached adapter が NAV に混入しないこと） |
| `test/mocks/FaultInjectingAdapter.sol` | 既存（`realBalance()` で真の残高を可視化。複数インスタンス化して A/B/C 独立に障害） |

（新規 mock/handler は不要——状態遷移ファズの資産をそのまま複数 adapter 面に流用）

---

## 実装シナリオと検査 MINV

### model (A) 該当シナリオ（実装）

| シナリオ | 内容 | 実装 | 判定 |
|---|---|---|---|
| **MA1** クロス隔離 | 健全移行 A→B 後、detached A を全障害化しても active B は無影響（NAV 可読・退出可） | `test_MA1_crossIsolation…` + `invariant_MINV1_5` | ✅ |
| **MA2** 退役残余非干渉+回収 | lossy force-detach で A に残余 stranded → B active 中は NAV に混入せず → A 再接続で残余回収・希薄化なし | `test_MA2_retiredResidual…` | ✅ |
| **MA3** 旧 adapter 再接続 | A→B→A（健全）round-trip で share/NAV 復元・希薄化なし | `test_MA3_reattach…` | ✅ |
| **MA4** 障害中移行 | A が totalAssets revert 中の strict 移行 A→B は revert（資金は A に安全保持）→ force-detach A→0（best-effort）→ 健全 B 接続で復旧。H-01/H-02 と整合 | `test_MA4_migrationDuringFault…` | ✅ |

### (B) 非該当（構造的に発生しない・1行根拠）

- **MB1-MB4（並存資金分散）**：`activeAdapter` 単数＋移行時全額 recall ゆえ、2 adapter に同時に資金が存在しない。→ 実装せず（構造的非該当）。

### 共通（registry 層）

| シナリオ | 内容 | 実装 | 判定 |
|---|---|---|---|
| **MR1** registry 整合 | 部分障害/退役下でも `getActiveAdapters` が壊れない・L-03 上限保持 | `invariant_MINV6_registryIntegrity` | ✅ |
| **MR2** 誤配線拒否 | asset/vault/governance mismatch adapter を拒否 | M-03（`ThirdReviewRemediation` 既存） | ✅ |

### MINV（複数 adapter 面で常時真）

| MINV | 内容 | 実装 | 判定 |
|---|---|---|---|
| **MINV-1/5** クロス隔離/残余非干渉 | NAV は idle + **active adapter のみ**を計上。detached/退役 adapter（障害・残余保持でも）は NAV に混入しない（`totalAssets ≤ idle + active_contribution`。revert 時は fallback `totalDebt()`） | Foundry invariant（10,240 calls）+ Echidna + MA1/MA2 | ✅ |
| **MINV-2** 集約 solvency | `convertToAssets(supply) ≤ totalAssets`（障害 adapter は honest・過大計上せず） | Foundry + Echidna | ✅ |
| **MINV-3** 常時退出（部分） | model A では「部分」＝移行残余の回収。lossy detach 後も recovered 分を退出可、A 分は write-off/force-detach 救済（＝状態遷移ファズ INV-1 と同一） | INV-1 + MA2 | ✅ |
| **MINV-4** 移行安全 | 任意の A→B→…→再接続×障害で二重計上/希薄化/honest 超 stuck なし | MINV-1/5 + MA1-MA4 + INV-2/4 | ✅ |
| **MINV-6** registry 整合 | 部分障害下で registry view/上限が壊れない | invariant + L-03 | ✅ |

---

## 発見・残存

**新規の実バグ = ゼロ。MINV-1〜6（＋既存 INV-1〜9）は全順序 × 全障害で保持。**
複数 adapter 面で新規反例なし（状態遷移ファズで解消済みの 2 件のハーネス誤判定以外に、複数 adapter 固有の
新規反例は発生せず）。特に **「片方障害 × 片方健全」で MINV-1/2/3 が崩れないこと**を MA1（detached 全障害 ×
active 健全）で実証。**残存＝なし。**

### 非空（vacuous 回避）の担保

- MINV-1/5（no-phantom）は、detached adapter を**実際に全障害化**（MA1）・**残余を実際に stranded**（MA2）した
  状態で NAV が混入しないことを直接アサート。
- MINV-3（部分退出）は「実際に assets を受領して退出」を MA1/MA2 でアサート（`got ≈ principal`）。
- 障害の実発火を確認（`pool[0].setRevertOnTotalAssets(true)` 後に active が別 adapter であること等）。

---

## 再現・実行

```bash
forge test --match-contract MultiAdapterFault -vv          # MINV invariant + MA1-MA4
echidna test/echidna/StateTransitionEchidna.sol --contract StateTransitionEchidna \
  --config echidna.yaml --test-limit 50000                 # echidna_no_phantom_cross_adapter 含む
./scripts/contract-audit.sh                                # OVERALL PASS
```

## Part B（該当なし）

MINV 違反（実バグ）は発見されなかったため、`REMEDIATION_PROPOSALS.md` への新規追記なし。
凍結 src（`2e8f059`）は無改変。**「新規違反ゼロ＝複数 adapter 面も収束」**と結論する。
（model B の資金分散は構造的に非該当のため、将来 concurrent 化する設計変更があれば本監査面の再実施が必要。）
