#!/usr/bin/env bash
# mutation-guard.sh — shared safety policy sourced by every mutation harness (ADR-008).
#
# A mutation job cp's mutants INTO src/core/*.sol and restores them in a trap. If the harness
# SIGKILLs the job, or a foreground loop hits the tool timeout, the trap may not fire and forge
# children keep looping — silently re-dirtying the working tree's source ("zombie contamination",
# seen 3x in Round 8). Structural fix: mutation MUST run only in a DEDICATED linked git worktree,
# never in the primary (freeze-target) worktree, so a leaked mutant can only ever dirty a
# throwaway tree. Process-group lifecycle (setsid + kill-group + worktree teardown) is owned by
# scripts/run-mutation-isolated.sh; this file only provides POLICY + a per-forge timeout so it
# never clobbers a mutation script's own `trap restore ...`.
#
# Source at the top of a mutation script:  . "$(dirname "$0")/mutation-guard.sh"
#   mutation_require_isolated_worktree   — abort (exit 5) unless run in a linked worktree
#   mutation_run <seconds> <cmd...>      — run forge under timeout --kill-after (no child outlives)

mutation_require_isolated_worktree() {
  if [ "${MUTATION_ALLOW_PRIMARY:-0}" = "1" ]; then
    echo "WARN: MUTATION_ALLOW_PRIMARY=1 — mutating the CURRENT tree (ADR-008 override)." >&2
    return 0
  fi
  local gd cd
  gd="$(git rev-parse --git-dir 2>/dev/null || echo x)"
  cd="$(git rev-parse --git-common-dir 2>/dev/null || echo y)"
  # primary worktree: git-dir == git-common-dir; linked worktree: they differ.
  if [ "$gd" = "$cd" ]; then
    cat >&2 <<EOF
REFUSING TO RUN: mutation must not run in the primary (freeze-target) worktree.
A zombie mutation loop here would re-dirty src/core/*.sol on the body tree (ADR-008).
Run it in a dedicated isolated worktree instead:

    scripts/run-mutation-isolated.sh mutation-diffscope.sh   # or mutation-test.sh [target]

(emergency override, discouraged: MUTATION_ALLOW_PRIMARY=1)
EOF
    exit 5
  fi
}

# Run a forge invocation under a hard timeout so a hung/mutated forge cannot outlive its
# classifier step. Falls back to a plain run if `timeout` is unavailable.
mutation_run() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=15s "${secs}s" "$@"
  else
    "$@"
  fi
}
