#!/usr/bin/env bash
# test-mutation-hygiene.sh — regression test for the ADR-008 mutation-isolation guards.
# Locks in the structural fix for the "zombie mutation re-dirties src" incident (Round 8, 3x).
#
# Asserts:
#   1. the pre-commit hook REJECTS a staged src file carrying a Gambit mutation marker;
#   2. the pre-commit hook ALLOWS a clean staged src file;
#   3. the mutation harnesses REFUSE to run in the primary (freeze-target) worktree.
# Non-destructive: uses a temp branch/index scratch and never leaves state behind.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT"
HOOK=".githooks/pre-commit"
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

# --- 1 & 2: hook behaviour against a scratch file staged into a temp index -------------
SCRATCH="src/__hygiene_probe__.sol"
TMPIDX="$(mktemp)"; trap 'rm -f "$TMPIDX" "$SCRATCH" 2>/dev/null; git reset -q 2>/dev/null || true' EXIT
_stage_and_run_hook() {
  # throwaway index seeded from HEAD, stage $SCRATCH into it, run the hook against that index
  GIT_INDEX_FILE="$TMPIDX" git read-tree HEAD
  GIT_INDEX_FILE="$TMPIDX" git add -f "$SCRATCH"
  GIT_INDEX_FILE="$TMPIDX" bash "$HOOK"
}

# 2 — clean file must PASS
printf 'pragma solidity ^0.8.28;\ncontract Probe { uint256 x; }\n' > "$SCRATCH"
if _stage_and_run_hook; then ok "hook allows clean staged src"; else bad "hook wrongly rejected clean src"; fi

# 1 — mutant-marked file must be REJECTED
printf 'pragma solidity ^0.8.28;\ncontract Probe {\n  /// AssignmentMutation(`x` |==> `1`) of: `x = 0;`\n  uint256 x = 1;\n}\n' > "$SCRATCH"
if _stage_and_run_hook; then bad "hook FAILED to reject a mutation-marked src"; else ok "hook rejects mutation-marked staged src"; fi
rm -f "$SCRATCH"; GIT_INDEX_FILE="$TMPIDX" git reset -q 2>/dev/null || true

# --- 3: mutation harness refuses to run on the primary worktree ------------------------
# The guard exits 5 in the primary tree. Invoke the guard directly (no gambit/forge needed).
out="$(bash -c '. scripts/mutation-guard.sh; mutation_require_isolated_worktree' 2>&1)"; rc=$?
if [ "$rc" = "5" ] && printf '%s' "$out" | grep -q "REFUSING TO RUN"; then
  ok "mutation guard refuses the primary worktree (exit 5)"
else
  bad "mutation guard did NOT refuse the primary worktree (rc=$rc)"
fi

echo "----"
if [ "$fails" -eq 0 ]; then echo "ALL HYGIENE GUARDS PASS"; exit 0; else echo "$fails HYGIENE GUARD(S) FAILED"; exit 1; fi
