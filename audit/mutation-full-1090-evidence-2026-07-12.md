# Full mutation re-run — evidence (S0-1)

> **看板 stat の再検証。** 硬化ハーネス（pre-flight canary 検証済）で正しい invocation により再実行し、
> ログを本ファイルに保全（as-run 証拠の単一ソース）。

## S0-1 追検証（2026-07-13）— 共有tree汚染時間帯との照合＝非重複＝看板は有効

構造欠陥（同一 working tree を2セッション共有）の発覚を受け、看板 run が汚染時間帯と
重なっていないかを git reflog / commit時刻 / セッション transcript の時刻で照合した。

- 凍結 src: `src` の git tree object は `9fa9796` = `main` = `d961dfc` で `af2a269838efa564972cf823b3e9364429ea8789` に一致（＝バイト同一・07-12 中の src commit 皆無）。
- 看板 run の実行窓: harness 導入 `71afda4`(07-12 17:50 UTC) 〜 証拠 commit `d961dfc`(07-12 21:29 UTC)。
- その窓に active だったセッションは **`f0fb3c76`（07-12 16:31–23:27 UTC）の1本のみ**（＝この run 自身のセッション）。
  他セッションは `63cd8a58`(〜07-12 02:20, 窓の15h前に終了)・`9b7933f9`(pid 1574, 07-13 05:26開始, 窓の8h後)で **重複なし**。
- 共有tree汚染（session A 測定中に session B が src 編集）が実際に起きたのは **07-13**（`9b7933f9`）で、看板 run の **翌日**。
- **判定: 看板 stat（94.6% / 1090・killed 1031 / survived 59）は汚染時間帯と重ならず、有効。訂正不要。**
  ＋ 硬化 harness の per-mutant restore と pre-flight canary（回帰 D–F で健全性を機械確認）により二重に担保。
- 恒久対策として、以降の測定は隔離 worktree でのみ実行し、全ラン src-freeze を機械検証する（[docs/operations/ADR-008](../docs/operations/ADR-008-one-session-one-worktree.md)）。

- 実行: `MUTATION_N=2000 MUTATION_SEED=0 scripts/mutation-test.sh src/core/SIXXVault.sol`（ダウンサンプル無し=1090 全件）
- 分類 invocation: `forge test --no-match-contract Fork -q`（MUTATION_MATCH 未設定 ＝ '*' 異常終了クラス非該当）
- pre-flight canary: **PASS**（未変異 src で 280 tests pass・invocation 健全と確認）
- commit: `71afda4`（src は凍結 tip 9fa9796 と一致）・seed=0・fuzz=64/invariant=16
- 日付: 2026-07-12

## 結果 = 看板と厳密一致（訂正不要・証明）

# Mutation testing — src/core/SIXXVault.sol

- mutants: 1090 (killed 1031 / survived 59)
- **mutation score: 94.6%**
- fuzz_runs=64 invariant_runs=16 (reduced for speed)

## Surviving mutants (test gaps — a change no test caught)

**→ killed 1031 / survived 59 / score 94.6% を再現。看板 stat は正当。**

## 生存 59 件（全記録）
```
SURVIVED mutant #15 [DeleteExpressionMutation] :: -        require(feeRecipient_ != address(0), "VAULT: zero fee recipient"); +        /// DeleteExpressionMutation(`require(feeRecipient_ != address(0), "VAULT: 
SURVIVED mutant #16 [RequireMutation] :: -        require(feeRecipient_ != address(0), "VAULT: zero fee recipient"); +        /// RequireMutation(`feeRecipient_ != address(0)` |==> `true`) of: `require
SURVIVED mutant #57 [DeleteExpressionMutation] :: -        _lastHarvestTimestamp = block.timestamp; +        /// DeleteExpressionMutation(`_lastHarvestTimestamp = block.timestamp` |==> `assert(true)`) of: `_las
SURVIVED mutant #58 [AssignmentMutation] :: -        _lastHarvestTimestamp = block.timestamp; +        /// AssignmentMutation(`block.timestamp` |==> `0`) of: `_lastHarvestTimestamp = block.timestamp;` +  
SURVIVED mutant #60 [AssignmentMutation] :: -        _lastHarvestTimestamp = block.timestamp; +        /// AssignmentMutation(`block.timestamp` |==> `1`) of: `_lastHarvestTimestamp = block.timestamp;` +  
SURVIVED mutant #63 [DeleteExpressionMutation] :: -        _lastReport = block.timestamp; +        /// DeleteExpressionMutation(`_lastReport = block.timestamp` |==> `assert(true)`) of: `_lastReport = block.time
SURVIVED mutant #64 [AssignmentMutation] :: -        _lastReport = block.timestamp; +        /// AssignmentMutation(`block.timestamp` |==> `0`) of: `_lastReport = block.timestamp;` +        _lastReport = 
SURVIVED mutant #66 [AssignmentMutation] :: -        _lastReport = block.timestamp; +        /// AssignmentMutation(`block.timestamp` |==> `1`) of: `_lastReport = block.timestamp;` +        _lastReport = 
SURVIVED mutant #91 [RequireMutation] :: -        require(shares > 0, "VAULT: zero shares"); // Part B P1 (RD5): symmetric guard +        /// RequireMutation(`shares > 0` |==> `false`) of: `require(sha
SURVIVED mutant #98 [SwapArgumentsOperatorMutation] :: -        require(shares > 0, "VAULT: zero shares"); // Part B P1 (RD5): symmetric guard +        /// SwapArgumentsOperatorMutation(`shares > 0` |==> `0 > shares
SURVIVED mutant #99 [DeleteExpressionMutation] :: -        _collectFees(); +        /// DeleteExpressionMutation(`_collectFees()` |==> `assert(true)`) of: `_collectFees();` +        assert(true);
SURVIVED mutant #100 [DeleteExpressionMutation] :: -        _collectFees(); +        /// DeleteExpressionMutation(`_collectFees()` |==> `assert(true)`) of: `_collectFees();` +        assert(true);
SURVIVED mutant #181 [IfStatementMutation] :: -            if (afterBal > beforeBal) profit = afterBal - beforeBal; +            /// IfStatementMutation(`afterBal > beforeBal` |==> `true`) of: `if (afterBal
SURVIVED mutant #236 [IfStatementMutation] :: -        if (emergencyShutdown || depositsPaused) return 0; +        /// IfStatementMutation(`emergencyShutdown || depositsPaused` |==> `true`) of: `if (emergen
SURVIVED mutant #245 [IfStatementMutation] :: -        if (!emergencyShutdown && _lockedUntil[owner] > block.timestamp) return 0; +        /// IfStatementMutation(`!emergencyShutdown && _lockedUntil[owner] 
SURVIVED mutant #280 [DeleteExpressionMutation] :: -        require(!emergencyShutdown, "VAULT: emergency shutdown"); +        /// DeleteExpressionMutation(`require(!emergencyShutdown, "VAULT: emergency shutdown
SURVIVED mutant #281 [RequireMutation] :: -        require(!emergencyShutdown, "VAULT: emergency shutdown"); +        /// RequireMutation(`!emergencyShutdown` |==> `true`) of: `require(!emergencyShutdow
SURVIVED mutant #286 [DeleteExpressionMutation] :: -        require(!depositsPaused, "VAULT: deposits paused"); +        /// DeleteExpressionMutation(`require(!depositsPaused, "VAULT: deposits paused")` |==> `as
SURVIVED mutant #287 [RequireMutation] :: -        require(!depositsPaused, "VAULT: deposits paused"); +        /// RequireMutation(`!depositsPaused` |==> `true`) of: `require(!depositsPaused, "VAULT: d
SURVIVED mutant #345 [BinaryOpMutation] :: -            uint256 newLock = block.timestamp + lockPeriod; +            /// BinaryOpMutation(`+` |==> `*`) of: `uint256 newLock = block.timestamp + lockPeriod
SURVIVED mutant #349 [IfStatementMutation] :: -            if (newLock > _lockedUntil[receiver]) { +            /// IfStatementMutation(`newLock > _lockedUntil[receiver]` |==> `true`) of: `if (newLock > _lo
SURVIVED mutant #366 [IfStatementMutation] :: -        if (!emergencyShutdown) { +        /// IfStatementMutation(`!emergencyShutdown` |==> `false`) of: `if (!emergencyShutdown) {` +        if (false) {
SURVIVED mutant #370 [DeleteExpressionMutation] :: -            require(block.timestamp >= _lockedUntil[owner], "VAULT: still locked"); +            /// DeleteExpressionMutation(`require(block.timestamp >= _lock
SURVIVED mutant #371 [RequireMutation] :: -            require(block.timestamp >= _lockedUntil[owner], "VAULT: still locked"); +            /// RequireMutation(`block.timestamp >= _lockedUntil[owner]` |
SURVIVED mutant #422 [IfStatementMutation] :: -        if (idle == 0) return; +        /// IfStatementMutation(`idle == 0` |==> `false`) of: `if (idle == 0) return;` +        if (false) return;
SURVIVED mutant #456 [IfStatementMutation] :: -        if (activeAdapter == address(0)) return; +        /// IfStatementMutation(`activeAdapter == address(0)` |==> `false`) of: `if (activeAdapter == address
SURVIVED mutant #463 [BinaryOpMutation] :: -        uint256 needed = assets - idle; +        /// BinaryOpMutation(`-` |==> `+`) of: `uint256 needed = assets - idle;` +        uint256 needed = assets+idle
SURVIVED mutant #470 [IfStatementMutation] :: -            if (needed > available) toWithdraw = available; +            /// IfStatementMutation(`needed > available` |==> `false`) of: `if (needed > available
SURVIVED mutant #478 [DeleteExpressionMutation] :: -            if (needed > available) toWithdraw = available; +            /// DeleteExpressionMutation(`toWithdraw = available` |==> `assert(true)`) of: `if (ne
SURVIVED mutant #479 [AssignmentMutation] :: -            if (needed > available) toWithdraw = available; +            /// AssignmentMutation(`available` |==> `0`) of: `if (needed > available) toWithdraw =
SURVIVED mutant #481 [AssignmentMutation] :: -            if (needed > available) toWithdraw = available; +            /// AssignmentMutation(`available` |==> `1`) of: `if (needed > available) toWithdraw =
SURVIVED mutant #485 [IfStatementMutation] :: -        if (toWithdraw == 0) return; +        /// IfStatementMutation(`toWithdraw == 0` |==> `false`) of: `if (toWithdraw == 0) return;` +        if (false) re
SURVIVED mutant #493 [BinaryOpMutation] :: -        uint256 received = IERC20(asset()).balanceOf(address(this)) - balBefore; +        /// BinaryOpMutation(`-` |==> `+`) of: `uint256 received = IERC20(ass
SURVIVED mutant #602 [IfStatementMutation] :: -                if (adapterBal > 0) { +                /// IfStatementMutation(`adapterBal > 0` |==> `true`) of: `if (adapterBal > 0) {` +                if (t
SURVIVED mutant #636 [DeleteExpressionMutation] :: -                catch { marked = 0; navReadOk = false; } +                /// DeleteExpressionMutation(`marked = 0` |==> `assert(true)`) of: `catch { marked = 
SURVIVED mutant #638 [AssignmentMutation] :: -                catch { marked = 0; navReadOk = false; } +                /// AssignmentMutation(`0` |==> `1`) of: `catch { marked = 0; navReadOk = false; }` +
SURVIVED mutant #639 [DeleteExpressionMutation] :: -                catch { marked = 0; navReadOk = false; } +                /// DeleteExpressionMutation(`navReadOk = false` |==> `assert(true)`) of: `catch { ma
SURVIVED mutant #641 [IfStatementMutation] :: -                if (marked > 0) { +                /// IfStatementMutation(`marked > 0` |==> `true`) of: `if (marked > 0) {` +                if (true) {
SURVIVED mutant #656 [BinaryOpMutation] :: -                    received = IERC20(asset()).balanceOf(address(this)) - balBefore; +                    /// BinaryOpMutation(`-` |==> `+`) of: `received = IE
SURVIVED mutant #662 [IfStatementMutation] :: -                if (!navReadOk) emit AdapterNavUnreadableOnDetach(det); +                /// IfStatementMutation(`!navReadOk` |==> `true`) of: `if (!navReadOk)
SURVIVED mutant #663 [IfStatementMutation] :: -                if (!navReadOk) emit AdapterNavUnreadableOnDetach(det); +                /// IfStatementMutation(`!navReadOk` |==> `false`) of: `if (!navReadOk
SURVIVED mutant #688 [DeleteExpressionMutation] :: -                    _lastReport = block.timestamp; +                    /// DeleteExpressionMutation(`_lastReport = block.timestamp` |==> `assert(true)`) of: `
SURVIVED mutant #689 [AssignmentMutation] :: -                    _lastReport = block.timestamp; +                    /// AssignmentMutation(`block.timestamp` |==> `0`) of: `_lastReport = block.timestamp;`
SURVIVED mutant #691 [AssignmentMutation] :: -                    _lastReport = block.timestamp; +                    /// AssignmentMutation(`block.timestamp` |==> `1`) of: `_lastReport = block.timestamp;`
SURVIVED mutant #713 [IfStatementMutation] :: -            if (depositsPaused) { +            /// IfStatementMutation(`depositsPaused` |==> `true`) of: `if (depositsPaused) {` +            if (true) {
SURVIVED mutant #733 [DeleteExpressionMutation] :: -        performanceFee = newFee; // always 0 +        /// DeleteExpressionMutation(`performanceFee = newFee` |==> `assert(true)`) of: `performanceFee = newFee;
SURVIVED mutant #734 [AssignmentMutation] :: -        performanceFee = newFee; // always 0 +        /// AssignmentMutation(`newFee` |==> `0`) of: `performanceFee = newFee; // always 0` +        performance
SURVIVED mutant #750 [IfStatementMutation] :: -        if (managementFee == 0) { +        /// IfStatementMutation(`managementFee == 0` |==> `true`) of: `if (managementFee == 0) {` +        if (true) {
SURVIVED mutant #772 [RequireMutation] :: -        require(newRecipient != address(0), "VAULT: zero address"); +        /// RequireMutation(`newRecipient != address(0)` |==> `false`) of: `require(newRec
SURVIVED mutant #779 [DeleteExpressionMutation] :: -        feeRecipient = newRecipient; +        /// DeleteExpressionMutation(`feeRecipient = newRecipient` |==> `assert(true)`) of: `feeRecipient = newRecipient;
SURVIVED mutant #786 [IfStatementMutation] :: -        if (managementFee == 0 || feeRecipient == address(0)) return 0; +        /// IfStatementMutation(`managementFee == 0 || feeRecipient == address(0)` |==
SURVIVED mutant #812 [IfStatementMutation] :: -        if (elapsed == 0) return 0; +        /// IfStatementMutation(`elapsed == 0` |==> `false`) of: `if (elapsed == 0) return 0;` +        if (false) return 
SURVIVED mutant #826 [IfStatementMutation] :: -        if (assets == 0 || supply == 0) return 0; +        /// IfStatementMutation(`assets == 0 || supply == 0` |==> `false`) of: `if (assets == 0 || supply ==
SURVIVED mutant #911 [IfStatementMutation] :: -            if (feeShares > 0) { +            /// IfStatementMutation(`feeShares > 0` |==> `true`) of: `if (feeShares > 0) {` +            if (true) {
SURVIVED mutant #973 [IfStatementMutation] :: -                if (adapterBal > 0) { +                /// IfStatementMutation(`adapterBal > 0` |==> `true`) of: `if (adapterBal > 0) {` +                if (t
SURVIVED mutant #984 [AssignmentMutation] :: -                        _totalDebt = 0; +                        /// AssignmentMutation(`0` |==> `1`) of: `_totalDebt = 0;` +                        _totalDebt
SURVIVED mutant #987 [DeleteExpressionMutation] :: -        require(newGovernance != address(0), "VAULT: zero address"); +        /// DeleteExpressionMutation(`require(newGovernance != address(0), "VAULT: zero a
SURVIVED mutant #988 [RequireMutation] :: -        require(newGovernance != address(0), "VAULT: zero address"); +        /// RequireMutation(`newGovernance != address(0)` |==> `true`) of: `require(newGo
SURVIVED mutant #1018 [DeleteExpressionMutation] :: -                revert("VAULT: mainnet gov must be a Timelock"); +                /// DeleteExpressionMutation(`revert("VAULT: mainnet gov must be a Timelock")
```
