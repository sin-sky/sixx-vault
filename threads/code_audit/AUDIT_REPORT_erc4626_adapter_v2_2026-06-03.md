# AUDIT REPORT v2 — `ERC4626Adapter` post-deploy diff (rescue / isFullyExited)

| | |
|---|---|
| 監査者 | Local Claude (Opus) — `security-review` 骨子 + 手動コードリーディング + Foundry PoC |
| 依頼 | `AUDIT_INSTRUCTION_erc4626_adapter_v2_2026-06-03.md` / thread_morpho_adapter |
| リポジトリ | `sin-sky/sixx-vault` @ `feat/erc4626-morpho-adapter` |
| 監査コミット | `8c05530`（ハードニング差分）／前回 v1 監査は `828ecfe` |
| 性質 | **post-deploy 検証 + 活性化前ゲート**（v2 はブロードキャスト完了済み） |
| v2 オンチェーン実体 | `0x83E6…8a8D`（登録済み・**未活性**・Etherscan 検証済みと申告） |
| 旧 v1 実体 | `0x4f6D6C9E815D37870307E524FCe4dcc822cd9ad2`（retire 対象） |
| 本番 SIXXVault | `0x5292A8DCd18C6512137e8cA6C21dB0dc6b830b31`（USDC・**非アップグレーダブル**） |
| 接続先 ERC-4626 | Gauntlet USDC Prime (ETH) `0xdd0f28e19C1780eb6396170735D45153D261490d` |

---

## 総合評価

| 深刻度 | 件数 | 内訳 |
|---|---|---|
| 🔴 Critical | **0** | — |
| 🟡 High | **0** | — |
| 🟠 Medium | **1** | **V2-M1**：`isFullyExited()` は view 追加のみで **どのオンチェーン呼出元も require していない** → M-G1 は契約レベルで**未クローズ（助言止まり）**。本活性化は非該当だが将来の migrate-out で要・手続き的強制 |
| 🟢 Low | **0** | — |
| ⚪️ Info | **2** | V2-I1 rescue は reentrant トークンを sweep 不能（fail-safe・許容）／V2-I2 script は OLD≠active を assert（良好） |

### スコープ（141 行差分のみ）
| 差分 | 結果 |
|---|---|
| `ERC4626Adapter.sol +41`（`rescue()` / `isFullyExited()` / `Rescued`） | rescue=✅ 安全（L-1 クローズ）／isFullyExited=⚠️ 未強制（V2-M1） |
| `RedeployERC4626Adapter.s.sol +100`（3 ガバナンス操作） | ✅ クリーン（chainid/gov/asset/OLD≠active を assert・`setAdapter` 不呼出） |
| オンチェーン実体 `0x83E6…8a8D` | ⏳ **ローカル独立検証不可**（public RPC 全滅）→ §5 照合コマンドで要確認 |

### 検証実績
- `forge build`（Solc 0.8.28 / OZ v5.6.1）✅／**非fork 55/55 PASS・0 fail**（v1 48 + v2 PoC 7）
- 必須 PoC 4 種（rescue(asset)/rescue(share)/悪性トークン再入/非governance）+ happy-path + M-G1 未強制実証 = **7/7 PASS**
- fork スイートは RPC 無しで未実行（§5 / 活性化前ブロッカー）

---

## 1. 最重点 (a) — `rescue()` のコア資産保護＋再入妥当性 → ✅ 安全（L-1 クローズ）

該当：`src/adapters/ERC4626Adapter.sol:333-341`
```solidity
function rescue(address token, address to) external nonReentrant {
    require(msg.sender == governance, "ADAPTER: not governance");        // 334
    require(to != address(0), "ADAPTER: zero to");                       // 335
    require(token != asset && token != address(vault), "ADAPTER: core protected"); // 336
    uint256 bal = IERC20(token).balanceOf(address(this));
    require(bal > 0, "ADAPTER: nothing to rescue");
    IERC20(token).safeTransfer(to, bal);
    emit Rescued(token, to, bal);
}
```

| 検査項目 | 判定 | 根拠 |
|---|---|---|
| 原資産 `asset`(USDC) ハード除外 | ✅ | `:336` 左辺。PoC-1 `rescue(asset)` → `core protected` revert |
| vault share（ERC-4626=元本）ハード除外 | ✅ | `:336` 右辺。PoC-2 `rescue(vaultShare)` → revert・**元本 totalAssets 不変** |
| **元本抜き取り経路の不在** | ✅ | 両コア除外により、rescue から原資産/share を動かす経路が存在しない |
| governance 限定 | ✅ | `:334`。PoC-4 非governance & sixxVault も revert（`not governance`） |
| zero-to / empty-balance ガード | ✅ | `:335,338`。happy-path PoC で両 revert 実証 |
| **任意 ERC20 再入の nonReentrant 妥当性** | ✅ | `nonReentrant` が rescue の**第一 modifier**。PoC-3：悪性トークンの `transfer` 内 re-entry が **`ReentrancyGuardReentrantCall()` で阻止**（具体 selector 一致）→ 外側 revert・**元本不変** |

**結論**：rescue はコア資産（原資産・share）双方をハード除外し、再入も含めて元本を一切触れない。**v1 finding L-1 はクローズ**。唯一の副作用は「悪性 reentrant トークンは sweep 不能（自爆）」だが、これは fail-safe で許容（V2-I1）。

---

## 2. 最重点 (b) — `isFullyExited()` の実効性 → 🟠 V2-M1（未クローズ・助言止まり）

該当：`src/adapters/ERC4626Adapter.sol:254-257`
```solidity
function isFullyExited() external view returns (bool) {
    return vault.convertToAssets(vault.balanceOf(address(this))) == 0;
}
```

### view 自体は正しい
PoC `test_poc_isFullyExited_viewIsCorrect`：空→`true` / 保有→`false`。floor 反映で「償還可能価値ゼロ」を正しく表現。

### しかし **どのオンチェーン呼出元も require していない**
- `grep` 全 `src/` `script/`：`isFullyExited` の参照は**自身の定義コメントとテストのみ**。`SIXXVault.setAdapter`（`:259-286`）に require は無い。
- 本番 `SIXXVault 0x5292…` は **非アップグレーダブル**＝この view を live `setAdapter` に後付け配線することは**構造的に不可能**。
- `RedeployERC4626Adapter.s.sol` は `setAdapter` を呼ばない。migrate-out スクリプトは**存在しない**。

### 実証：未強制ゆえに stranding が起こり得る
PoC `test_poc_MG1_notEnforced_setAdapter_strands_illiquid`：
1. illiquid な ERC-4626 に 50,000 預入（`isFullyExited()==false`）
2. `liquidCap=0`（完全枯渇）に設定
3. governance が **別 adapter へ `setAdapter`** → recall は maxWithdraw=0 でクランプ・**何も引けないまま成功**（require が無い）
4. 結果：旧 adapter に**資金 stranded**・`vault.totalAssets()` が 50,000 未満に下振れ・`isFullyExited()` は依然 `false`

→ **M-G1 は契約レベルで閉じていない（advisory）**。view を足しただけで保護は発動しない。

### 影響範囲と緊急度
- **本活性化（Aave→Morpho）には非該当**：今回は (i) 切り離す旧 adapter が Aave（完全流動）で recall full、(ii) 方向が migrate-*in*。stranding は migrate-*out* かつ illiquid 時のみ。
- 可逆（governance が旧 adapter へ `setAdapter` し戻せば再算入）。
- **緊急度：中（将来の migrate-out 前まで）／本活性化：低**。

### 必須対応（手続き的強制）
将来 Morpho を**出る**移行を行うスクリプトは、`setAdapter` 実行**前に**必ず：
```solidity
require(ERC4626Adapter(oldAdapter).isFullyExited(), "migrate-out: old not fully exited");
```
を入れること（=「全量引戻し完了の確認」をスクリプト層で担保）。本 view はそのための部品であり、強制は呼出側の責務であることをランブックに明記。

---

## 3. `RedeployERC4626Adapter.s.sol`（3 ガバナンス操作）→ ✅ クリーン

| 操作 | 該当 | 判定 |
|---|---|---|
| 1. v2 deploy（params 現行同一） | `:74-80` | ✅ asset=USDC/vault=Gauntlet Prime/sixxVault=0x5292/gov=0x58cd |
| 2. `registerAdapter(v2,"DeFi","…v2")` | `:83` | ✅ |
| 3. `setAdapterStatus(OLD,false)` | `:86-88` | ✅ `isActive(OLD)` 確認後のみ |
| ★ `setAdapter` 不呼出（active=Aave 据置） | — | ✅ スクリプト内に `setAdapter` 呼出なし（grep 確認） |

衛生ガード：`chainid==1`(`:50`) / `sender==gov`(`:54`) / `vault.asset()==USDC`(`:57`) / **`activeBefore != OLD`(`:69`＝ライブ戦略を誤 retire しない)** / 秘密鍵は `vm.envUint` のみ・ハードコードなし。**V2-I2＝良好な防御**。

---

## 4. PoC 試行結果（`test/ERC4626AdapterV2PoC.t.sol`・7/7 PASS）

| # | PoC | 種別 | 結果 |
|---|---|---|---|
| 1 | `rescue(asset)` | 必須 | ✅ `ADAPTER: core protected` revert |
| 2 | `rescue(vault share)` | 必須 | ✅ revert・元本不変 |
| 3 | 悪性トークン再入 | 必須 | ✅ `ReentrancyGuardReentrantCall()` で阻止・元本不変・evil 未 sweep |
| 4 | 非 governance 呼出（attacker & sixxVault） | 必須 | ✅ `ADAPTER: not governance` revert |
| 5 | happy-path（foreign 全量回収）+ zero-to + empty-bal | 補強 | ✅ 全 revert/回収を実証 |
| 6 | `isFullyExited()` view 正当性 | (b) | ✅ 空/保有を正しく反映 |
| 7 | **M-G1 未強制で illiquid 切り離し→stranding** | (b) | ✅ setAdapter が require せず資金 stranded を実証 |

---

## 5. オンチェーン post-deploy 照合（⏳ ローカル独立検証不可・要実行）

public RPC（llamarpc/cloudflare/ankr）が 526・レート制限・要 API key で**ローカルから検証できず**。下記を gov 不要・read-only で実行し、申告（登録済み/未活性/検証済み）と一致を確認すること：

```bash
V2=0x83E6...8a8D            # ← 完全アドレスに置換
VAULT=0x5292A8DCd18C6512137e8cA6C21dB0dc6b830b31
REG=0x0b487365d5E7FD5d324D7221340413a096492542
OLD=0x4f6D6C9E815D37870307E524FCe4dcc822cd9ad2
AAVE=0x8857b9Fb5B0E87aDa7a104B7F8D7FaCAA892487C
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
PRIME=0xdd0f28e19C1780eb6396170735D45153D261490d

# 1) v2 のパラメータ整合（4 つとも一致すべき）
cast call $V2 "asset()(address)"      --rpc-url $ETH_RPC_URL   # == USDC
cast call $V2 "vault()(address)"      --rpc-url $ETH_RPC_URL   # == PRIME
cast call $V2 "sixxVault()(address)"  --rpc-url $ETH_RPC_URL   # == VAULT
cast call $V2 "governance()(address)" --rpc-url $ETH_RPC_URL   # == 0x58cd…b150

# 2) registry：v2 active / OLD 無効化
cast call $REG "isActive(address)(bool)" $V2  --rpc-url $ETH_RPC_URL   # true
cast call $REG "isActive(address)(bool)" $OLD --rpc-url $ETH_RPC_URL   # false  ← retire 確認

# 3) ★ active は Aave 据置（setAdapter 未実行の証明）
cast call $VAULT "activeAdapter()(address)" --rpc-url $ETH_RPC_URL     # == AAVE

# 4) Etherscan 検証ソース == commit 8c05530（bytecode 一致）を UI で確認
```

**照合チェックリスト（活性化前に全 ✅ 必須）**
- [ ] v2 `asset/vault/sixxVault/governance` が全一致
- [ ] `registry.isActive(v2)==true`
- [ ] `registry.isActive(OLD)==false`（旧 retire 済）
- [ ] `vault.activeAdapter()==Aave`（資金未移動）
- [ ] Etherscan 検証ソース == `8c05530`

---

## 6. 前回 finding 追跡（v1 → v2）

| v1 finding | v1 状態 | v2 状態 |
|---|---|---|
| L-1 rescue 不在 | 🟢 Low（推奨） | ✅ **クローズ**（governance限定 rescue・コア二重除外・再入耐性を PoC 実証） |
| M-G1 migrate-out stranding | 🟠 Medium（推奨） | 🟠 **未クローズ（V2-M1）**：view 追加のみ・require 未配線。**手続き的強制が必須**（本活性化は非該当） |
| L-2 Morpho 流動性依存の引出 liveness | 🟢 Low（信頼仮定） | 変化なし（外部依存） |
| L-3 移行*入* soft-fail で idle 滞留 | 🟢 Low（運用） | 変化なし（M-3 で資金安全） |
| H-1〜H-4 / M-1〜M-5 | ✅ | コア未変更・整合維持 |

---

## 7. 最終判定

# 🟢 条件付き GO（活性化＝setAdapter）

**理由**：v2 差分（141 行）に Critical/High はゼロ。`rescue()` はコア資産（原資産・share）双方をハード除外し再入耐性も実証済みで、**元本抜き取り経路は存在しない**（L-1 クローズ）。`RedeployERC4626Adapter.s.sol` は 3 ガバナンス操作を安全に実施し `setAdapter` を呼ばず active=Aave を維持。

ただし以下を**活性化前の条件**とする：

### ブロッカー（活性化前に必須）
1. **§5 オンチェーン照合 5 項目を全 ✅**（v2 パラメータ一致・registry v2 active / OLD 無効化・active=Aave・Etherscan==`8c05530`）。public RPC 不通のため本監査では未検証。
2. **実 ETH RPC で `ERC4626AdapterEthMigrationForkTest` を green 実行**（v1 ブロッカー継続）。
3. **活性化直前に Gauntlet USDC Prime の供給 cap headroom ≥ `vault.totalAssets()` を再確認**（v1 ブロッカー継続）。

### 留意（本活性化は非ブロッカー・将来必須）
- **V2-M1**：`isFullyExited()` は**契約レベルで未強制**。本活性化（Aave→Morpho・migrate-in）には無影響だが、**将来 Morpho を出る移行スクリプトは `require(adapter.isFullyExited())` を setAdapter 前に必ず入れること**。非アップグレーダブル vault のため、強制はスクリプト/手続き層が唯一の担保。ランブックに明記必須。

### 業務側（スコープ外）
- TVL ≥ $50M・スプレッド ≥ +0.8% は業務判断。技術的活性化の安全性は上記ブロッカー充足を以て GO。

---

## 付録：再現
```bash
cd ~/sixx-vault-audit && git checkout feat/erc4626-morpho-adapter   # 8c05530 を含む
git submodule update --init --recursive && forge build
forge test --no-match-contract "Fork"                              # 55/55 PASS
forge test --match-contract ERC4626AdapterV2PoC -vvv               # 7/7 PASS（必須PoC）
```
成果物：`test/ERC4626AdapterV2PoC.t.sol`（v2 PoC 7 本）。Slither/Aderyn/Mythril は当環境未導入（ユーザー方針）→ CI での Slither 回帰を推奨。
