#!/usr/bin/env bash
# run-mutation-isolated.sh — the ONLY sanctioned way to run a mutation harness (ADR-008).
#
# Creates a throwaway linked git worktree, runs the given mutation script inside it (in its own
# process group), and ALWAYS tears the worktree down — even on Ctrl-C / SIGTERM / SIGKILL of a
# child. Any mutant that leaks from a zombie loop can therefore only ever dirty the disposable
# worktree, never the primary (freeze-target) tree. Reports are copied back to the primary
# reports/mutation/ dir.
#
# Usage:  scripts/run-mutation-isolated.sh mutation-diffscope.sh [args...]
#         scripts/run-mutation-isolated.sh mutation-test.sh [target.sol]
set -uo pipefail

PRIMARY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:?usage: run-mutation-isolated.sh <mutation-script.sh> [args...]}"; shift || true
[ -f "$PRIMARY/scripts/$SCRIPT" ] || { echo "no such mutation script: scripts/$SCRIPT"; exit 2; }

# Deterministic worktree path (no Date/rand needed): PID-scoped, under the repo parent.
WT="$PRIMARY-mut-$$"
REF="$(git -C "$PRIMARY" rev-parse HEAD)"

cleanup() {
  # kill the whole process group (child mutation job + its forge/solc), then remove the worktree.
  kill -- -$$ 2>/dev/null || true
  git -C "$PRIMARY" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT" 2>/dev/null || true
  git -C "$PRIMARY" worktree prune 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "==> creating isolated mutation worktree at $WT (@ $REF)"
git -C "$PRIMARY" worktree add --force --detach "$WT" "$REF" >/dev/null
# submodules are not checked out in a linked worktree — reuse the primary's lib/ via symlink.
rm -rf "$WT/lib"; ln -s "$PRIMARY/lib" "$WT/lib"

echo "==> running scripts/$SCRIPT in the isolated worktree"
( cd "$WT" && setsid bash "scripts/$SCRIPT" "$@" ) ; rc=$?

# copy any produced reports back to the primary tree for inspection
if [ -d "$WT/reports/mutation" ]; then
  mkdir -p "$PRIMARY/reports/mutation"
  cp -f "$WT/reports/mutation/"* "$PRIMARY/reports/mutation/" 2>/dev/null || true
fi
echo "==> mutation run rc=$rc; worktree will be removed. Reports in reports/mutation/"
exit "$rc"
