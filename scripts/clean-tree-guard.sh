#!/usr/bin/env bash
# clean-tree-guard.sh — refuse to run static analysis on a CONTAMINATED source tree.
#
# Why this exists (S0-2, 2026-07-12): a Gambit mutation run swaps a MUTANT into src/ while
# it works, and a crash mid-run (or a concurrent run) can leave that mutant — or a
# gambit_out/mutants directory — behind. If Slither/Aderyn/Halmos/forge then read that tree
# they analyse code that is NOT the committed source: a mutated contract can invent a High
# or hide one, silently corrupting every downstream finding. This happened once (a static
# analyser read a tree mid-mutation and reported a phantom "Misused boolean" High).
#
# Contract: exit 0 = clean (safe to analyse). exit 1 = contaminated. NEVER swallow the
# result (`|| true`) in callers — exit != 0 MUST be treated as FAIL.
#
# Usage: clean-tree-guard.sh [ROOT]   (ROOT defaults to the repo root; overridable for tests)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
reasons=""

# (1) Mutation artifacts anywhere outside lib/ — a run in progress, crashed, or not cleaned.
arts=""
[ -d "$ROOT/gambit_out" ]      && arts="$arts gambit_out/"
[ -d "$ROOT/gambit_diff_out" ] && arts="$arts gambit_diff_out/"
mdirs="$(find "$ROOT" -maxdepth 4 -type d -name mutants 2>/dev/null | grep -v "/lib/" | head -3)"
mfiles="$(find "$ROOT" -maxdepth 4 -type f -name '*.mutant' 2>/dev/null | grep -v "/lib/" | head -3)"
[ -n "$mdirs" ]  && arts="$arts $(echo "$mdirs"  | tr '\n' ' ')"
[ -n "$mfiles" ] && arts="$arts $(echo "$mfiles" | tr '\n' ' ')"
[ -n "${arts// /}" ] && reasons="mutation artifacts present:$arts"

# (2) Source tree not clean vs git — the analysed src/ MUST equal the committed source, or
#     the run is not reproducible and may be reading a leftover mutant. Outside a git work
#     tree (e.g. the extracted handoff bundle) skip this check but keep the artifact check.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty="$(git -C "$ROOT" status --porcelain -- src 2>/dev/null)"
  if [ -n "$dirty" ]; then
    reasons="${reasons:+$reasons | }src/ has uncommitted changes (analysis would not match committed source)"
  fi
else
  echo "clean-tree-guard: not a git work tree — git-dirty check skipped (artifact check still enforced)"
fi

if [ -n "$reasons" ]; then
  echo "CLEAN-TREE GUARD: CONTAMINATED — $reasons" >&2
  exit 1
fi
echo "CLEAN-TREE GUARD: clean (src/ matches committed source; no mutation artifacts)"
exit 0
