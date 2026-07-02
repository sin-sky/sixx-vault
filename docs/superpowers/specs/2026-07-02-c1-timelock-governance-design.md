# C-1 設計: TimelockController ガバナンス＋緊急停止 guardian

**2026-07-02。** 敵対的監査 CRITICAL C-1（`SECURITY_AUDIT_FINDINGS_2026-07-02.md`）への構造的対処。**「Vault は timelock 不在＋単一 governance 鍵が Vault と Registry の両方を支配 → 1ブロックで evil adapter に切替え TVL 100% ドレイン可」**を、遅延と最小権限で塞ぐ。

> ⚠️ **非 upgradeable のため、本修正は次の再デプロイ（新 Vault/Registry コントラクト）に一括で乗る**。監査前ハードニング（A/B/C/M13-16/nonReentrant・Venus dust trap）は実装済み。C-1 が最後の未実装。SHIN 方針＝**全修正を実装・テスト完了 → 外部監査 → mainnet 再デプロイ（バラバラに再デプロイしない）**。本 spec のスコープは**コントラクト変更＋Timelock 配線＋Deploy スクリプト＋テスト**。実際の mainnet 移行（デプロイ・ユーザー withdraw/redeposit）は SHIN のオンチェーン操作。

---

## 1. SHIN 確定事項（WHAT）

- OZ `TimelockController` を導入。**minDelay = 48h**。**proposer / executor = 既存 Gnosis Safe（2-of-3）**。
- **SIXXVault + AdapterRegistry の両 governance を Timelock に移行**。
- **`setEmergencyShutdown` のみ Timelock をバイパスして即時実行可**。他の governance 操作（`setAdapter`/`setLockPeriod`/`setPerformanceFee`/`setManagementFee`/`setFeeRecipient`/registry の `registerAdapter`/`setAdapterStatus`/`proposeGovernance`）は 48h 遅延。

## 2. アクセス制御の形（HOW）＝本 spec の核心

### 2.1 guardian ロール（新規・SIXXVault のみ）
`governance` を Timelock に移すと、素朴には `setEmergencyShutdown` も 48h 遅延してしまい「緊急弁」が機能しない。そこで **`setEmergencyShutdown` を即時に呼べる別ロール `guardian` を追加**する（OZ の「guardian は即 pause／resume は full governance」パターン）。`guardian` = 既存 Gnosis Safe（Timelock の proposer/executor と同一 Safe を直接保持）。

### 2.2 方向の非対称（🟠 SHIN 離席のため推奨案で確定・レビューで要確認）
- **緊急停止 ON（`setEmergencyShutdown(true)`）= guardian OR governance が即時**。ON は「運用停止＋adapter から資金 recall＋ユーザーは即時出金可（lock 免除）」＝**保全方向**。
- **緊急停止 OFF（`setEmergencyShutdown(false)`）= governance（Timelock 48h）のみ**。OFF は「通常運用への復帰＝deposit 再開・lock 再適用」＝**慎重方向**。

**根拠**：鍵漏洩した guardian が起こせる最大被害は「一時停止（DoS）」に限定され、それも governance が 48h で解除できる。**資産は一切奪えない**（`setAdapter` は依然 Timelock）。最小権限。

> 代替案（不採用）：ON/OFF 両方 guardian 即時＝運用は機敏だが漏洩 guardian が高速トグルで撹乱可能（グリーフィング）。資産窃取は不可だが最小権限に劣る。

### 2.3 guardian の可変性
`setGuardian(address newGuardian) external onlyGovernance`（＝Timelock 48h・zero-check・イベント）。guardian 鍵のローテを可能に。address(0) 不可（無効化したい場合は Timelock 自身を指定＝緊急も 48h 化）。

## 3. コントラクト変更（実装対象）

### 3.1 `SIXXVault.sol`
- **state**：`address public guardian;` 追加。
- **constructor**：引数に `address guardian_` 追加。`require(guardian_ != address(0), "VAULT: zero guardian")`。`guardian = guardian_;`。
- **`setEmergencyShutdown(bool active)`**：`onlyGovernance` を除去し、関数冒頭で分岐:
  ```solidity
  function setEmergencyShutdown(bool active) external override nonReentrant {
      if (active) {
          require(msg.sender == guardian || msg.sender == governance, "VAULT: not guardian/gov");
      } else {
          require(msg.sender == governance, "VAULT: not governance");
      }
      // ... 既存ロジック（flag first → try/catch recall）不変
  }
  ```
- **`setGuardian`**：新規 `external onlyGovernance`＋zero-check＋`emit GuardianChanged(old,new)`。
- **event**：`event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);`。
- 他の onlyGovernance 関数は**無変更**（governance=Timelock になることで自動的に 48h 化）。

### 3.2 `ISIXXVault.sol`
- `function guardian() external view returns (address);`
- `function setGuardian(address newGuardian) external;`
- `event GuardianChanged(...)`。（`setEmergencyShutdown` のシグネチャは不変。）

### 3.3 `AdapterRegistry.sol`
- **コード変更なし**。`constructor(address governance_)` に Timelock アドレスを渡すだけ（新規デプロイ時）。全 registry 操作が 48h 化。

### 3.4 `TimelockController`
- **自作しない**。`lib/openzeppelin-contracts/.../governance/TimelockController.sol` を Deploy スクリプトでデプロイ。

### 3.5 `script/Deploy.s.sol`
- デプロイ順：**① TimelockController**（`minDelay=48h`, `proposers=[SAFE]`, `executors=[SAFE]`, `admin=address(0)`＝self-administered）→ **② AdapterRegistry(governance=timelock)** → **③ SIXXVault(governance=timelock, guardian=SAFE, registry=registry, ...)** → ④ Adapter デプロイ＋`registry.registerAdapter`（=Timelock 経由になるため、初回は Timelock schedule/execute or デプロイ直後に別途）。
- SAFE アドレスはチェーン別（Eth/Arb/BNB の 2-of-3・LATEST 確定値）。`executors=[SAFE]` 明示（open executor `address(0)` は誰でも execute 可＝不採用）。

## 4. トラストモデルと残存リスク（外部監査への申し送り）

- SHIN 確定＝**Vault と Registry は同一 Timelock を governance に共有**。監査 finding が推奨した「Registry を別 principal に」ではなく、**48h 遅延を独立ブレーキ**とする方式。→ **48h の間にユーザーが exit できることが保護の前提**。
- **必須の運用要件**：Timelock の `CallScheduled` イベントを監視し、`setAdapter` 等がキューされたらユーザーに周知するアラート bot（finding の推奨と一致）。これが無いと 48h 遅延は形骸化。
- **残存リスク（監査で opine 対象）**：①Safe が proposer/executor かつ guardian を兼ねるため、Safe 鍵が漏洩すると「悪意 setAdapter を 48h キュー」＋「guardian として緊急停止を拒否」が同一主体で可能。48h は**オフチェーン対応の窓**であり万能でない。②lock 期間中のユーザーは 48h 以内に exit できない場合がある（guardian=攻撃者だと緊急停止による lock 免除も期待できない）。→ より強い形は「Registry を別マルチシグ」or「guardian を Safe と別主体」。本 spec は SHIN 決定（同一 Timelock）に従い、これらを監査論点として明示。

## 5. テスト（TDD）

**unit（MockUSDC/MockAdapter・fork 不要）**:
1. guardian が `setEmergencyShutdown(true)` を即時成功／state・recall・イベント確認。
2. guardian が `setEmergencyShutdown(false)` → **revert（"not governance"）**。
3. governance が ON/OFF 両方成功。
4. 第三者（非 guardian・非 governance）が ON/OFF とも revert。
5. `setGuardian` は governance のみ／zero-check revert／イベント／state 反映／旧 guardian は失効。
6. guardian トリガの緊急停止でも A（try/catch recall）・B（lock 免除出金）が従来通り。

**integration（in-process Timelock）**:
7. OZ `TimelockController` をデプロイし vault/registry の governance に設定 → `setAdapter` は Safe 直呼びで revert（not governance）、schedule→`vm.warp(+48h)`→execute で成功。
8. `setEmergencyShutdown(true)` は Timelock を経由せず guardian(Safe) 直呼びで即時成功（バイパス実証）。

**deploy**:
9. `Deploy.s.sol` の配線（governance=timelock, guardian=safe, registry.governance=timelock）を deploy test でアサート。

既存の非fork スイート（現 61）＋fork（7）に回帰なし。`FOUNDRY_EVM_VERSION=cancun` 必須（[[sixx-vault-forge-on-old-glibc]]）。

## 6. スコープ外（YAGNI）
- 実際の mainnet デプロイ・ユーザー資金移行（SHIN オンチェーン操作）。
- アラート bot 実装（別タスク・運用）。
- Registry の別 principal 化・guardian の別主体化（SHIN が同一 Timelock を選択。監査論点として記録のみ）。
- admin フロント（sixx-admin）の Timelock 対応 UI（移行後の別タスク）。
