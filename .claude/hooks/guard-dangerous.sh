#!/bin/bash
# On-chain danger guard (PreToolUse, matcher=Bash).
# Blocks `cast send` and `forge script ... --broadcast` (on-chain sends/deploys).
# Reads the tool input from BOTH the modern stdin JSON payload AND the legacy
# CLAUDE_TOOL_INPUT env var, so it fires regardless of how the harness passes input.
# Fail-closed: on a match it exits 2 (blocks) even if notification fails.
# NOTE: this is defense-in-depth. The primary hard guard is permissions.deny in
#       settings.json ("Bash(cast send:*)" / "Bash(forge script:* --broadcast*)"),
#       which is enforced even under bypassPermissions.

STDIN_JSON="$(cat 2>/dev/null || true)"
INPUT="${CLAUDE_TOOL_INPUT:-} ${STDIN_JSON}"

if printf '%s' "$INPUT" | grep -qE "cast send|forge script.*--broadcast|forge script.*-b "; then
  echo "🔴 DANGER: オンチェーン操作を検出しました。SHINの確認が必要です。中断します。"
  bash "$(git rev-parse --show-toplevel 2>/dev/null)/.claude/hooks/notify-shin.sh" \
    danger "オンチェーン操作を検出: $INPUT" 2>/dev/null || true
  exit 2
fi

exit 0
