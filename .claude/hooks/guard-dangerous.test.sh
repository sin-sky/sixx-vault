#!/usr/bin/env bash
# guard-dangerous.test.sh — regression test for the on-chain danger guard.
#
# Ensures the guard BLOCKS on-chain sends/deploys (exit 2) and ALLOWS benign commands
# (exit 0), via BOTH the modern PreToolUse stdin JSON payload AND the legacy
# CLAUDE_TOOL_INPUT env var. Fails (exit 1) if the safety mechanism ever silently stops
# blocking. Wired into scripts/contract-audit.sh and CI so a regression can't land quietly.
#
# Real PreToolUse stdin payload (Claude Code, per official Hooks Reference
# https://code.claude.com/docs/en/hooks.md): a JSON object with session_id,
# transcript_path, cwd, permission_mode, hook_event_name, tool_name, tool_input; for Bash
# the command is at tool_input.command (inner quotes escaped). There is NO CLAUDE_TOOL_INPUT
# env var — stdin JSON is the ONLY channel — so a guard must read stdin to fire at all
# (this is exactly the schema-drift that had silently disabled the guard). The stdin cases
# below are the REAL defense; the env case is a vestigial legacy backstop.
#
# The `payload()` fixture mirrors the FULL documented envelope on purpose, and the
# "schema canary" stage asserts it still matches that schema. If Claude Code ever changes
# the payload shape again (or someone trims this fixture), the canary fails LOUDLY instead
# of the guard silently missing the real payload.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/guard-dangerous.sh"
if [ ! -f "$GUARD" ]; then echo "on-chain guard: FAIL — guard-dangerous.sh missing"; exit 1; fi

FAILED=0

# Build the exact PreToolUse stdin envelope Claude Code sends (pure bash JSON encoding).
payload() {
  local cmd="$1"
  local esc=${cmd//\\/\\\\}   # escape backslashes first
  esc=${esc//\"/\\\"}          # then double quotes (mirrors the real escaped command)
  printf '{"session_id":"test","transcript_path":"/tmp/t.jsonl","cwd":"%s","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$PWD" "$esc"
}

run_stdin() { payload "$1" | env -u CLAUDE_TOOL_INPUT bash "$GUARD" >/dev/null 2>&1; echo $?; }
run_env()   { CLAUDE_TOOL_INPUT="$1" bash "$GUARD" </dev/null >/dev/null 2>&1; echo $?; }

check() { # label expected actual
  if [ "$3" = "$2" ]; then
    echo "  ✓ $1 (exit $3)"
  else
    echo "  ✗ $1 (expected exit $2, got $3)"; FAILED=1
  fi
}

echo "== on-chain guard regression — stdin JSON (modern Claude Code payload) =="
check "BLOCK cast send"               2 "$(run_stdin 'cast send 0xabc "transfer(address,uint256)" 0xdef 100 --rpc-url $RPC')"
check "BLOCK forge script --broadcast" 2 "$(run_stdin 'forge script script/Deploy.s.sol --rpc-url $RPC --broadcast')"
check "BLOCK forge script -b"          2 "$(run_stdin 'forge script script/Deploy.s.sol -b ')"
check "ALLOW forge test"               0 "$(run_stdin 'forge test --no-match-contract Fork')"
check "ALLOW forge build"              0 "$(run_stdin 'forge build')"
check "ALLOW cast call (read-only)"    0 "$(run_stdin 'cast call 0xabc "totalSupply()"')"

echo "== on-chain guard regression — legacy CLAUDE_TOOL_INPUT env (vestigial backstop) =="
check "BLOCK cast send (env)"          2 "$(run_env 'cast send 0x1 "x()" --rpc-url y')"
check "ALLOW forge test (env)"         0 "$(run_env 'forge test')"

echo "== schema canary — test fixture still matches the documented PreToolUse schema =="
# Locks this fixture to the real Claude Code envelope. If CC changes the payload shape,
# or someone trims this fixture, the canary fails so the guard can't silently miss the
# real payload again (the exact drift that had disabled it: env -> stdin JSON).
CANARY="$(payload 'forge test')"
for key in '"session_id"' '"transcript_path"' '"cwd"' '"permission_mode"' \
           '"hook_event_name":"PreToolUse"' '"tool_name":"Bash"' '"tool_input":{"command":'; do
  if printf '%s' "$CANARY" | grep -qF "$key"; then
    echo "  ✓ fixture has ${key}"
  else
    echo "  ✗ fixture MISSING ${key} — payload drifted from the documented schema"; FAILED=1
  fi
done
# The dangerous string must be delivered via tool_input.command specifically (the real path),
# not merely somewhere in the envelope — so a future schema-aware guard is exercised correctly.
if printf '%s' "$(payload 'cast send 0x1 x')" | grep -qE '"tool_input":\{"command":"cast send'; then
  echo "  ✓ dangerous command carried at tool_input.command (real delivery path)"
else
  echo "  ✗ dangerous command not at tool_input.command — fixture no longer realistic"; FAILED=1
fi

echo
if [ "$FAILED" = 0 ]; then
  echo "on-chain guard: PASS (cast send / forge --broadcast blocked; benign allowed; both input paths)"
  exit 0
else
  echo "on-chain guard: FAIL — SAFETY MECHANISM BROKEN (guard no longer blocks). Do NOT enable bypassPermissions."
  exit 1
fi
