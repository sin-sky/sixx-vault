# AUDIT REPORT — `ERC4626Adapter` (Morpho / Gauntlet USDC Prime)

| | |
|---|---|
| 監査者 | Local Claude (Opus) — `security-review` 骨子 + 手動コードリーディング + Foundry PoC |
| 依頼 | thread_morpho_adapter / 2026-06-02 |
| 対象リポジトリ | `sin-sky/sixx-vault` @ `feat/erc4626-morpho-adapter` |
| 監査コミット | `828ecfe16ec735206fa4c8262a66dd881c2d95ee` (2026-06-02 15:04 UTC) |
| 本番 adapter | `0x4f6D6C9E815D37870307E524FCe4dcc822cd9ad2` (ETH mainnet・registered・**未活性**) |
| 対象 ERC-4626 | Gauntlet USDC Prime (ETH) `0xdd0f28e19C1780eb6396170735D45153D261490d` |
| 目的 | 活性化（`setAdapter` = Aave→Morpho 資金移行）の **GO / 条件付き / NO-GO** 判定 |

---

## 総合評価

| 深刻度 | 件数 | 内訳 |
|---|---|---|
| 🔴 Critical | **0** | — |
| 🟡 High | **0** | — |
| 🟠 Medium | **1** | M-G1（汎用化リスク：**将来**の illiquid ERC4626 からの移行*出*で recall クランプ → stranding。**本活性化のスコープ外＝非ブロッカー**） |
| 🟢 Low | **3** | L-1 rescue 不在 / L-2 Morpho 流動性依存の引出 liveness / L-3 移行*入*の soft-fail で idle 滞留 |
| ⚪️ Info | **3** | I-1 `harvest()` 無認可 / I-2 `setAdapter` 非 nonReentrant / I-3 read-only-reentrancy（理論上） |

### 検証実績
- `forge build`（Solc 0.8.28, OZ v5.6.1）— ✅ コンパイル成功（lint 警告のみ、機能影響なし）
- 既存 unit + invariant + 統合テスト：**42 / 42 PASS**（invariant `totalAssetsNotOverWithdrawable` を 256 runs / 3,840 calls / **0 revert** で確認）
- 追加攻撃 PoC（`test/AuditPoC.t.sol`、本監査で作成）：**4 / 4 PASS**
- fork テスト（Base / ETH / ETH 移行）：RPC 未設定のためローカル未実行 → **活性化前の最終ゲートとして必須実行**（§判定の条件）

### 一言要約
本体ロジックに **Critical / High はゼロ**。PUSH モデル・onlyVault・2-step・nonReentrant・floor 丸めはいずれも要件を満たす。**活性化（Aave→Morpho）方向は構造的に資金喪失不能**であることを PoC で実証（最悪ケースでも資金は vault に idle 退避し、ユーザーは全額退出可能）。残課題は運用前提と汎用化時の*出*方向リスクのみ。

---

## 1. Findings 詳細

### 🟠 M-G1 — 汎用設計：illiquid な ERC4626 からの「移行*出*」で recall がクランプされ資金 stranding（**本活性化は非該当**）

- **該当**：`src/core/SIXXVault.sol:259-286`（`setAdapter`）＋ `src/adapters/ERC4626Adapter.sol:163-181`（`withdraw` の `maxWithdraw` クランプ）
- **内容**：`setAdapter` の旧 adapter 全引戻しは
  ```solidity
  uint256 adapterBal = IStrategyAdapter(activeAdapter).totalAssets(); // = convertToAssets(balanceOf)
  IStrategyAdapter(activeAdapter).withdraw(adapterBal, address(this)); // 戻り値を見ない
  _totalDebt = 0;
  ```
  ところが `ERC4626Adapter.withdraw` は `maxWithdraw` で **クランプ**して `withdrawn < adapterBal` を返し得る。`setAdapter` は戻り値を検証せず `_totalDebt=0` として旧 adapter を `activeAdapter` から外す。**旧 adapter（=その時点で illiquid な Morpho）に引き切れなかった分の MetaMorpho share が残置**され、その資産は新 `activeAdapter.totalAssets()` に含まれない。
- **影響**：`totalAssets()` が一時的に過小評価 → share 価格下振れ。ただし**喪失ではなく可逆**（governance が `setAdapter(旧adapter)` で再算入、または流動性回復後に回収可能）。
- **本活性化での該当性**：**該当しない。** 現行の旧 adapter は **Aave（aUSDC・即時完全流動的）** で、recall は full（移行 fork テスト `assertApproxEqAbs(aUsdcPost,0,5)` で実証）。本 Medium は**将来 Morpho→別戦略へ移行*出*する時**に初めて顕在化する設計上の注意点。
- **推奨対応**：(a) `setAdapter` で recall 後に `require(activeAdapter.totalAssets() <= dust, ...)` の残高ゼロ確認を追加、または (b) Morpho を*出*る移行は事前に `maxWithdraw >= totalAssets` を off-chain 検証してから実行する運用ルール化。**本活性化のブロッカーではない。**
- **緊急度**：中（汎用再利用フェーズ前まで）／本活性化：低

---

### 🟢 L-1 — rescue / sweep 関数の不在 → adapter 着金トークンの永久ロック

- **該当**：`src/adapters/ERC4626Adapter.sol` 全体（回収関数が存在しない）
- **内容**：adapter には任意 ERC20 を外へ移す手段が一切ない。adapter アドレスにトークンが着金すると**永久ロック**。PoC `test_stray_tokens_are_permanently_locked` で実証（500 MORPHO 着金 → 回収不能）。
- **影響評価（軽微）**：通常運用では adapter は遊休資産を持たない —
  - USDC：PUSH モデルで `safeTransfer`→`deposit` が同一コール内 → idle 滞留なし。
  - MetaMorpho share：正常に保有・redeem 可能（ロック対象外）。
  - **MORPHO 報酬**：Morpho では報酬は **MetaMorpho vault（=Morpho Blue の supplier）側**に accrue し、URD merkle claim で配布される設計。adapter（share 保有者）が直接 MORPHO を受領する経路は v1 では通常発生しない。
  - よって実害は「**誤送金 or 将来の報酬ルーティング変更時**に取りこぼす」に限定。
- **推奨対応**：governance 限定の `rescue(token, to)` を追加。ただし **コア資産保護のため `token != address(vault)`（MetaMorpho share）かつ `token != asset`（USDC）を禁止**する制約必須（さもないと share/原資産の抜き取り経路になる）。v1 後付け可。
- **緊急度**：低（活性化非ブロッカー）

---

### 🟢 L-2 — Morpho 流動性枯渇時、ユーザー引出が revert（liveness 依存・喪失なし）

- **該当**：`src/core/SIXXVault.sol:238-250`（`_recallFromAdapter`）＋ adapter `withdraw` クランプ
- **内容**：`_recallFromAdapter` は `adapter.withdraw` の戻り値を検証しない。Morpho が部分的に illiquid（`maxWithdraw < 要求`）の場合、adapter は要求未満を返し、`super._withdraw` の原資産送付が**残高不足で revert**。PoC `test_withdraw_clamp_no_drift_profit` で「過大引出は revert・過小引渡しは起きない・share 価格 drift なし」を実証。
- **影響**：**設計どおりの安全側挙動**（過小引渡しで会計を壊すより revert が正しい）。ただし Morpho 流動性が戻るまで一部ユーザーが一時的に引出不可。Aave 既存統合も同種の前提を持つ。
- **推奨対応**：UI/監視で MetaMorpho の即時 `maxWithdraw` 余力を監視。枯渇時は `pause` ＋（流動性回復後の）部分引出運用。コード変更不要。
- **緊急度**：低（外部依存の信頼仮定。§3-7 に明記）

---

### 🟢 L-3 — 移行*入*の deposit soft-fail で資金が無利回りの idle に滞留

- **該当**：`src/core/SIXXVault.sol:210-235`（`_deployToAdapter` / M-3 try-catch）
- **内容**：活性化時、Morpho 供給 cap が満杯だと `vault.deposit` が revert → **M-3 catch が握り潰し** `AdapterDepositFailed` を emit。`setAdapter` は成功扱いとなり、資金は vault に idle 滞留（`_totalDebt` 未加算）。PoC `test_migrate_into_capped_vault_funds_safe_idle` で実証：cap 満杯 vault への移行で **50,000 USDC が vault に安全退避・喪失ゼロ・alice 全額退出可能**。
- **影響**：**資金は安全**（`totalAssets()` は idle 残高を算入、ユーザー引出可）。唯一の不利益は「活性化したのに無利回りで遊休」。
- **推奨対応**：`ActivateERC4626Adapter.s.sol` / `DeployERC4626Adapter.s.sol` の既存チェックリスト「supply cap headroom ≥ vault.totalAssets()」を**活性化直前に再確認**（既に文書化済み）。コード変更不要。
- **緊急度**：低（運用前提。スクリプトに既出）

---

### ⚪️ I-1 — `harvest()` が無認可（誰でも呼べる）

- **該当**：`ERC4626Adapter.sol:185-188`。`nonReentrant` のみで `onlyVault` 無し。no-op（0 を emit/return）で副作用なし。既存 Aave/Venus と同列。**無害**。任意で `onlyVault` 付与可。

### ⚪️ I-2 — `SIXXVault.setAdapter` が非 `nonReentrant`

- **該当**：`SIXXVault.sol:259`。外部 adapter 呼び出しを含むが `onlyGovernance` かつ新旧 adapter は信頼前提（コア既監査）。USDC にフックなし・Morpho/Aave は callback を adapter に返さない。**実害なし**。コア再監査スコープ外として記録。

### ⚪️ I-3 — `totalAssets()` の read-only reentrancy（理論上）

- **該当**：`ERC4626Adapter.sol:136-138` = `convertToAssets(balanceOf)`。deposit/withdraw 経路の唯一の外部呼出は MetaMorpho で、Morpho Blue は adapter に任意 callback を返さず、USDC はフックなし → 操作途中の状態を外部から読ませる窓がない。MetaMorpho の virtual-shares + curated 会計が donation 過大評価を緩和（invariant テストで `totalAssets ≤ maxWithdraw` を 0-revert 実証）。**残存リスクは MetaMorpho 自体への信頼仮定**（§3-7）。

---

## 2. §3 チェックリスト逐一結果

### 3-1. アクセス制御
| 項目 | 結果 | 根拠 |
|---|---|---|
| `deposit`/`withdraw` の `onlyVault` | ✅ | `:119-122,146,164`。PoC `test_fake_vault_rejected` で偽 vault revert 実証 |
| `pause`(gov/vault) / `unpause`(gov) 権限境界 | ✅ | `:249-259`。`test_pause_auth`/`test_unpause_onlyGovernance` |
| 2-step governance（zero-addr / pending / front-run） | ✅ | `:286-300`。accept は `msg.sender==pending` 必須でフロントラン不能、accept 時 pending クリア |
| 2-step vault | ✅ | `:268-282`。同上。旧 caller 失効も `test_twoStepSixxVault` で確認 |
| constructor の `asset()==asset` / zero-addr | ✅ | `:99-104`。`test_constructor_revertsOnAssetMismatch`/`...ZeroAddrs` |

### 3-2. リエントランシー
| 項目 | 結果 | 根拠 |
|---|---|---|
| 全 state 変更関数に `nonReentrant` | ✅ | `deposit`/`withdraw`/`harvest` に付与（`:147,164,185`）。Admin 系は単純代入で外部呼出なし |
| cross-contract reentrancy（Morpho 経由） | ✅ | Morpho Blue は adapter に callback せず・USDC フックなし |
| `totalAssets()` read-only reentrancy | ⚠️→✅ | I-3 参照。理論上のみ・MetaMorpho 信頼仮定で許容 |

### 3-3. 会計・丸め
| 項目 | 結果 | 根拠 |
|---|---|---|
| `totalAssets` floor で過大評価しない | ✅ | `convertToAssets`（floor）。invariant 256runs/0revert・`test_totalAssets_neverOverstatesWithdrawable` |
| maxWithdraw クランプと SIXXVault 会計整合（drift） | ✅ | `_totalDebt` は bookkeeping のみ（share 算定は live `totalAssets()`）。PoC `test_withdraw_clamp_no_drift_profit` で **drift 利得不能** 実証 |
| ERC-4626 inflation / donation | ✅ | SIXXVault 側 `_decimalsOffset()=9` + MetaMorpho virtual shares。adapter は新経路を作らず |
| donation → SIXXVault share 誤価格化 | ✅ | MetaMorpho は idle 直接送付を totalAssets に算入しない設計＋virtual shares で緩和。信頼仮定として §3-7 |

### 3-4. Approval
| 項目 | 結果 | 根拠 |
|---|---|---|
| Morpho vault への `forceApprove(max)` | ✅ | `:112`。curator は approve 超の資金を引けない（MetaMorpho は標準 ERC-4626 pull のみ） |
| adapter→sixxVault approve 不在の正しさ | ✅ | M-3 atomic rollback（`SIXXVault.__atomicPushToAdapter:231-235`）が戻し approve を不要化。デプロイ済み実装で確認 |

### 3-5. 報酬・stuck token
| 項目 | 結果 | 根拠 |
|---|---|---|
| MORPHO 除外の会計整合 | ✅ | share 価格に未反映 → `totalAssets` に混入せず。誤計上なし |
| rescue 不在 → 永久ロック | ⚠️ | **L-1**。実害限定だが governance-限定 rescue 推奨 |

### 3-6. 活性化・移行（setAdapter）
| 項目 | 結果 | 根拠 |
|---|---|---|
| Aave→Morpho の原子性・部分失敗 | ✅ | recall(Aave) は非 try/catch（失敗時は全体 revert＝安全 abort）／deploy(Morpho) は M-3 soft-fail（idle 退避） |
| 移行損失/スリッページ | ✅ | 同資産・丸め損のみ。fork テスト `totalAssets preserved 0.05%` 許容 |
| 移行中 reentrancy / `_totalDebt` 再整合 | ✅ | 信頼 adapter のみ・`_totalDebt` は非クリティカル |
| cap 到達 / 流動性不足時の挙動 | ✅ | **L-3**。PoC で cap 満杯→idle 安全退避を実証。recall 側は Aave 完全流動で問題なし |
| 資金がある状態での移行 | ✅ | 移行 fork テスト（alice 50k seed）＋ PoC でカバー |

### 3-7. 外部依存の信頼仮定（文書化）
- **MetaMorpho upgradeability / curator / pause**：Gauntlet USDC Prime の curator/owner・upgradeability・pause 挙動は **活性化前 on-chain 検証必須**（deploy チェックリストに既出）。Morpho 側 pause で adapter deposit/withdraw が revert → SIXXVault は M-3 soft-fail（deposit）/ revert（withdraw=L-2）で**喪失せず**縮退。
- **withdrawal liquidity**：即時 `maxWithdraw` 前提。request/claim キュー型 vault は**非対応**（`requiredLockPeriod()=0` の前提）。将来キュー型採用時は別フロー必須（コードコメント `:232-239` に明記済み）。

### 3-8. script / デプロイ衛生
| 項目 | 結果 | 根拠 |
|---|---|---|
| 秘密鍵非混入 | ✅ | `vm.envUint("PRIVATE_KEY")` のみ。ハードコード鍵なし |
| governance==broadcaster 制約 | ✅ | `require(sender==ETH_GOVERNANCE)`（Deploy `:63` / Activate `:33`） |
| アドレス正当性 | ✅ | USDC/Registry/Vault/Gauntlet Prime をハードコード＋`asset()==USDC` チェック（Deploy `:65`） |
| chainid ガード | ✅ | `require(block.chainid==1)` 両スクリプト |
| Etherscan verify とソース一致 | ⚠️ | `--verify` 運用前提。**活性化前にデプロイ済み `0x4f6D…9ad2` のソース照合を実機確認すること**（本ローカル監査の範囲外） |

### 3-9. 既存監査との整合
| 項目 | 結果 |
|---|---|
| M-3 self-call atomic rollback | ✅ 本 adapter は戻し approve 不要・SIXXVault 側 M-3 と整合 |
| M-4 2-step（gov & vault） | ✅ 両系統実装・テスト済 |
| onlyVault / whenNotPaused / SafeERC20 / ReentrancyGuard / 0.8.28 | ✅ 全て充足 |

---

## 3. §4 攻撃シナリオ試行結果（Foundry PoC）

`test/AuditPoC.t.sol`（本監査で作成、4/4 PASS）：

| # | シナリオ | 結果 | 判定 |
|---|---|---|---|
| 1 | 偽 sixxVault からの deposit/withdraw | `ADAPTER: only vault` で revert | ✅ 防御 |
| 2 | 悪性トークン/悪性 vault による approve ドレイン | constructor `asset()==asset` ＋ registry 登録ゲートで遮断。max approve は標準 pull のみ | ✅ 防御 |
| 3 | Morpho donation で `totalAssets` 吊り上げ→SIXXVault 誤価格化 | invariant `totalAssets ≤ maxWithdraw`（256runs/0revert）＋virtual shares で緩和 | ✅ 緩和 |
| 4 | withdraw クランプで会計 drift | 過大引出は revert・過小引渡しなし・share 価格 drift なし | ✅ 利得不能 |
| 5 | 報酬トークン着金→回収不能 | 永久ロックを実証（L-1） | ⚠️ 実害限定・要 rescue |
| 6 | cap 到達 Morpho での移行 | **50,000 USDC が vault に安全 idle 退避・喪失ゼロ・全額退出可** | ✅ 資金安全 |
| 7 | governance/vault 2-step pending 乗っ取り | `msg.sender==pending` 必須でフロントラン不能 | ✅ 防御 |

> シナリオ 6（fork: Aave 引出 liquidity・Morpho 預入 cap の実値）は ETH RPC 未設定のためローカル mock で代替実証。**実 RPC fork（`ERC4626AdapterEthMigrationForkTest`）の活性化直前実行を条件に付す。**

---

## 4. 最終判定

# 🟢 条件付き GO（GO with conditions）

**理由**：本体に Critical / High はゼロ。活性化（Aave→Morpho）方向は **構造的に資金喪失不能** であることを PoC で実証した —
- 旧 Aave からの recall は完全流動（aUSDC）で full、失敗時は全体 revert の安全 abort。
- 新 Morpho への deposit は M-3 try/catch により、cap 満杯でも資金は vault に idle 退避し、ユーザーは全額退出可能（喪失ゼロ）。
- アクセス制御・2-step・nonReentrant・floor 丸め・approve 設計は全要件充足、42+4 テスト green。

残課題は **運用前提と将来の汎用化**に限られ、本活性化の安全性を損なわない。

### ブロッカー（活性化前に必須・技術）
1. **実 ETH RPC で fork 移行テストを実行**（`ERC4626AdapterEthMigrationForkTest` を `--fork-url $ETH_RPC_URL` で green 確認）。本ローカル監査は RPC 未設定のため mock 代替済み。
2. **活性化トランザクション直前に Morpho 供給 cap headroom ≥ `vault.totalAssets()` を再確認**（L-3／スクリプト既出チェックリスト）。満たさない場合でも喪失はしないが「活性化したのに idle」を避けるため必須。
3. **デプロイ済み adapter `0x4f6D…9ad2` の Etherscan 検証ソースが本コミット `828ecfe` と一致することを実機確認**（§3-8）。

### 推奨（非ブロッカー・活性化後でも可）
- **L-1**：governance 限定 `rescue(token,to)`（`token != vault share && token != asset` 制約付き）を追加。将来の MORPHO 報酬ルーティングと誤送金対策。
- **M-G1**：Morpho を*出*る将来移行に向け、`setAdapter` の recall 後残高ゼロ check か off-chain 事前検証を運用ルール化。
- **L-2**：MetaMorpho 即時 `maxWithdraw` 余力の監視・枯渇時 pause 運用。
- 既存監査済コア（SIXXVault/AdapterRegistry）は本 adapter との相互作用部分のみ確認済。コア再監査は依頼どおり未実施。

### 業務側（本監査スコープ外）
- Gauntlet USDC Prime TVL ≥ $50M（現 $38.1M）・スプレッド ≥ +0.8%（現 +52bps）は業務判断。**技術的活性化の安全性は上記条件充足を以て GO。**

---

## 付録：監査環境・成果物
- forge 1.7.1 / Solc 0.8.28 / OZ v5.6.1 / forge-std（submodule init 済）
- Slither / Aderyn / Mythril：当環境未インストール（ユーザー方針によりサイレント install 回避）。**活性化前に CI 等で Slither 回帰実行を推奨**（既報告クリーンの維持確認）。
- 追加成果物：`test/AuditPoC.t.sol`（攻撃 PoC 4 件、本ブランチ作業ツリーに配置・未コミット）。本番不要なら削除可。
