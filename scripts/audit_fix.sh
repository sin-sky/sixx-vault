#!/bin/bash
# audit_fix.sh — 監査修正を自動実行するオーケストレータープロンプト
# 使い方: cd /workspaces/sixx-vault && bash scripts/audit_fix.sh

export PATH="$HOME/.foundry/bin:$PATH"

claude --print "
あなたは sixx-vault のスマートコントラクトエンジニアです。CLAUDE.md を読んでから作業してください。

## タスク：監査 must-fix 5件の実装

以下を順番に実装してください。各ステップで forge build と forge test を実行して通過を確認してから次へ進むこと。

---

### STEP 1: LOCK-BASE（共通 helper 追加）
src/core/SIXXVault.sol に以下の internal helper を追加（既存コードの変更なし、追加のみ）:
\`\`\`solidity
function _isLocked(address user) internal view returns (bool) {
    return block.timestamp < _lockedUntil[user];
}
\`\`\`
forge build で確認。コミット: fix(vault): LOCK-BASE add _isLocked helper

---

### STEP 2: H-2（シェア転送 lock バイパス修正）
src/core/SIXXVault.sol に _update override を追加:
\`\`\`solidity
function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0)) {
        require(!_isLocked(from), "VAULT: shares locked");
    }
    super._update(from, to, value);
}
\`\`\`
forge test で確認。コミット: fix(vault): H-2 block share transfer while locked

---

### STEP 3: H-3（grief attack 修正）
src/core/SIXXVault.sol の _deposit 内の lock 延長ロジックを修正。
caller == receiver の場合のみ lock を延長するよう変更。
forge test で確認。コミット: fix(vault): H-3 restrict lock extension to self-deposit

---

### STEP 4: H-4（maxWithdraw / maxRedeem ERC-4626 準拠）
src/core/SIXXVault.sol に以下を追加:
\`\`\`solidity
function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
    if (_isLocked(owner)) return 0;
    return super.maxWithdraw(owner);
}
function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
    if (_isLocked(owner)) return 0;
    return super.maxRedeem(owner);
}
\`\`\`
forge test で確認。コミット: fix(vault): H-4 maxWithdraw/maxRedeem respect lock period

---

### STEP 5: H-1（AdapterRegistry チェック追加）
src/core/SIXXVault.sol の setAdapter() に Registry ホワイトリストチェックを追加。
forge test で確認。コミット: fix(vault): H-1 enforce AdapterRegistry whitelist in setAdapter

---

### STEP 6: M-1（collectFees 式修正）
src/core/SIXXVault.sol の collectFees() の feeShares 計算式を dilution mint 式に修正:
feeShares = feeAssets * totalSupply() / (totalAssets() - feeAssets)
forge test で確認。コミット: fix(vault): M-1 fix collectFees dilution math

---

### STEP 7: テスト追加
test/SIXXVault.t.sol に以下のテストを追加して全通過を確認:
- test_lockBypassViaTransfer (H-2)
- test_lockGriefingByAttacker (H-3)
- test_maxWithdraw_returnsZeroWhenLocked (H-4)
- test_setAdapter_rejectsUnregisteredAdapter (H-1)
forge test で全通過確認。コミット: test(vault): add regression tests for H-1/H-2/H-3/H-4

---

全STEP完了後に forge test の結果サマリーを出力してください。
"
