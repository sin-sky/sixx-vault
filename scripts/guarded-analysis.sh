#!/usr/bin/env bash
# guarded-analysis.sh — run an audit MEASUREMENT under a concurrent-edit tripwire.
#
# Root cause (2026-07-13): two Claude sessions shared one working tree; while one measured,
# the other edited src/. Slither/Aderyn/mutation/invariant all silently read a tree being
# rewritten underneath them. clean-tree-guard.sh proves the tree is clean+isolated at the
# START of a run; THIS wrapper proves it stayed frozen for the WHOLE run:
#
#   1. clean-tree-guard.sh --require-isolated   (dedicated worktree, clean tree, no artifacts)
#   2. snapshot BEFORE  = sha256 of every source input (src/ test/ script/ + config)
#   3. run the command   (NO `|| true`; its exit code is preserved)
#   4. snapshot AFTER
#   5. BEFORE != AFTER  -> someone wrote src/ mid-run -> DISCARD the result, exit 5 (FAIL),
#                          regardless of the command's own exit code
#   6. command exit != 0 -> exit that code (FAIL)
#
# A tool that legitimately mutates src/ itself (mutation-test.sh restores between mutants) must
# NOT be wrapped whole here — pass --allow-target <file> to exclude that ONE file from the
# tripwire, so a concurrent edit to any OTHER source file is still caught. mutation-test.sh
# uses this to watch every file except the one Gambit is actively swapping.
#
# The tree operated on defaults to this script's repo (scripts/..); override with
# GUARDED_ANALYSIS_ROOT for tests. The guard script itself is always resolved next to us.
#
# Usage:
#   guarded-analysis.sh <label> [--allow-target <file>] -- <command> [args...]
# Exit: 0 pass · 5 src changed mid-run · 6 tree not clean/isolated at start · <cmd code> on cmd fail
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/clean-tree-guard.sh"
ROOT="${GUARDED_ANALYSIS_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"

LABEL="${1:-analysis}"; shift || true
ALLOW_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-target) ALLOW_TARGET="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "guarded-analysis: unexpected arg before --: $1" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "guarded-analysis: no command after --" >&2; exit 2; }

# Hash of all source inputs under ROOT, optionally excluding one legitimately-mutated target.
# Mirrors clean-tree-guard.sh's src_hash but supports the --allow-target exclusion.
snap() {
  {
    find "$ROOT/src" "$ROOT/test" "$ROOT/script" -type f -name '*.sol' 2>/dev/null \
      | { [ -n "$ALLOW_TARGET" ] && grep -vF "$ROOT/$ALLOW_TARGET" || cat; }
    for c in foundry.toml remappings.txt echidna.yaml; do [ -f "$ROOT/$c" ] && echo "$ROOT/$c"; done
  } | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s  %s\n' "${f#"$ROOT"/}" "$(sha256sum "$f" | awk '{print $1}')"
      done | sha256sum | awk '{print $1}'
}

echo "== guarded-analysis [$LABEL] (root=$ROOT) =="

# 1. clean + isolated at start (hard gate — NOT swallowed)
if ! "$GUARD" --require-isolated "$ROOT"; then
  echo "guarded-analysis[$LABEL]: FAIL — tree not clean/isolated at start (see clean-tree guard above)" >&2
  exit 6
fi

# 2. snapshot before
BEFORE="$(snap)"
echo "  src snapshot (before): $BEFORE ${ALLOW_TARGET:+(excluding $ALLOW_TARGET)}"

# 3. run the measured command, preserving its exit code
"$@"; CMD_RC=$?

# 4/5. snapshot after — did anyone touch src/ mid-run?
AFTER="$(snap)"
if [ "$BEFORE" != "$AFTER" ]; then
  echo "guarded-analysis[$LABEL]: FAIL (exit 5) — SOURCE CHANGED MID-RUN." >&2
  echo "  before=$BEFORE  after=$AFTER" >&2
  echo "  A concurrent writer edited src/ while the measurement ran. Results are CONTAMINATED" >&2
  echo "  and DISCARDED. Re-run in an isolated worktree with no other session touching the tree." >&2
  exit 5
fi
echo "  src snapshot (after):  $AFTER  — unchanged (no concurrent edit)"

if [ "$CMD_RC" -ne 0 ]; then
  echo "guarded-analysis[$LABEL]: command exited $CMD_RC — FAIL"
  exit "$CMD_RC"
fi
echo "guarded-analysis[$LABEL]: PASS (tree frozen for the whole run)"
exit 0
