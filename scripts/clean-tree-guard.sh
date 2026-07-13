#!/usr/bin/env bash
# clean-tree-guard.sh — refuse to run static analysis on a CONTAMINATED source tree.
#
# Why this exists (S0-2, 2026-07-12 → hardened 2026-07-13): two independent failure modes
# corrupted the audit's MEASUREMENTS:
#
#   (a) SELF-contamination — a Gambit mutation run swaps a MUTANT into src/ while it works;
#       a crash mid-run (or a leftover gambit_out/) can leave that mutant behind. Slither/
#       Aderyn/forge then analyse code that is NOT the committed source (phantom High/hidden
#       High).
#   (b) CONCURRENT contamination (root cause, found 2026-07-13) — TWO Claude sessions shared
#       ONE working tree. While session A measured, session B edited src/ for the next round.
#       Every value session A produced was read off a tree being rewritten underneath it. This
#       is the true origin of the earlier mutation "false-kill" and the Aderyn mutant-phantom:
#       not a single accident but a STRUCTURAL defect of sharing a work tree.
#
# The fix treats measurement as something that may ONLY happen on a private, verified-clean,
# verified-frozen tree:
#   1. --require-isolated : refuse unless we are in a DEDICATED linked git worktree (never the
#      shared main tree). One session = one worktree.
#   2. working tree clean  : `git status --porcelain` (minus the repo's tracked-but-ignored
#      out/ + cache/ build artifacts) MUST be empty, or the analysed source != committed source.
#   3. no mutation artifacts: gambit_out/ , mutants/ , *.mutant anywhere outside lib/ -> refuse.
#   4. --print-hash        : emit a deterministic content hash of ALL source inputs so a caller
#      can snapshot it BEFORE and AFTER a run and prove nobody touched src/ mid-run
#      (see scripts/guarded-analysis.sh — the concurrent-edit detector).
#
# Contract: exit 0 = clean (safe to analyse). exit != 0 = contaminated / not isolated. NEVER
# swallow the result (`|| true`) in callers — exit != 0 MUST be treated as FAIL.
#
# Usage:
#   clean-tree-guard.sh [--require-isolated] [ROOT]      # gate (exit 0/1)
#   clean-tree-guard.sh --print-hash [ROOT]              # print source-input hash, exit 0
#   REQUIRE_ISOLATED_WORKTREE=1 clean-tree-guard.sh [ROOT]   # env form of --require-isolated
set -uo pipefail

REQUIRE_ISOLATED="${REQUIRE_ISOLATED_WORKTREE:-0}"
PRINT_HASH=0
ROOT=""
for a in "$@"; do
  case "$a" in
    --require-isolated) REQUIRE_ISOLATED=1 ;;
    --print-hash)       PRINT_HASH=1 ;;
    --*)                echo "clean-tree-guard: unknown option: $a" >&2; exit 2 ;;
    *)                  ROOT="$a" ;;
  esac
done
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── Deterministic hash of every SOURCE INPUT the analysers read ───────────────
# All *.sol under src/ test/ script/, plus the build/analysis config. Path + content, sorted,
# folded into one sha256. Stable across worktrees (paths are repo-relative). This is the
# concurrent-edit tripwire: if it differs before vs after a run, someone wrote src/ mid-run.
src_hash() {
  local root="$1" f rel
  {
    find "$root/src" "$root/test" "$root/script" -type f -name '*.sol' 2>/dev/null
    for c in foundry.toml remappings.txt echidna.yaml; do [ -f "$root/$c" ] && echo "$root/$c"; done
  } | LC_ALL=C sort | while IFS= read -r f; do
        rel="${f#"$root"/}"
        printf '%s  %s\n' "$rel" "$(sha256sum "$f" | awk '{print $1}')"
      done | sha256sum | awk '{print $1}'
}

if [ "$PRINT_HASH" = "1" ]; then
  src_hash "$ROOT"
  exit 0
fi

reasons=""

# (0) Isolation — measurement MUST run in a DEDICATED linked worktree, never the shared main
#     tree. A linked worktree's git-dir (.git/worktrees/<name>) differs from the common git-dir
#     (.git); in the main tree they are identical. This is what mechanically forbids two
#     sessions measuring/editing the same tree (the 2026-07-13 root cause).
if [ "$REQUIRE_ISOLATED" = "1" ]; then
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gd="$(cd "$ROOT" && git rev-parse --absolute-git-dir 2>/dev/null)"
    cd_="$(cd "$ROOT" && realpath "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null)"
    if [ -z "$gd" ] || [ -z "$cd_" ] || [ "$gd" = "$cd_" ]; then
      reasons="NOT an isolated worktree (measurement must run in a dedicated linked worktree, not the shared main tree — see docs/operations/ADR-008)"
    fi
  else
    reasons="--require-isolated set but $ROOT is not a git work tree"
  fi
fi

# (1) Mutation artifacts anywhere outside lib/ — a run in progress, crashed, or not cleaned.
arts=""
[ -d "$ROOT/gambit_out" ]      && arts="$arts gambit_out/"
[ -d "$ROOT/gambit_diff_out" ] && arts="$arts gambit_diff_out/"
mdirs="$(find "$ROOT" -maxdepth 4 -type d -name mutants 2>/dev/null | grep -v "/lib/" | head -3)"
mfiles="$(find "$ROOT" -maxdepth 4 -type f -name '*.mutant' 2>/dev/null | grep -v "/lib/" | head -3)"
[ -n "$mdirs" ]  && arts="$arts $(echo "$mdirs"  | tr '\n' ' ')"
[ -n "$mfiles" ] && arts="$arts $(echo "$mfiles" | tr '\n' ' ')"
[ -n "${arts// /}" ] && reasons="${reasons:+$reasons | }mutation artifacts present:$arts"

# (2) Working tree clean — the analysed source MUST equal the committed source. We check the
#     WHOLE porcelain (not just src/) so a stray edit to test/ or config is caught too, minus
#     out/ + cache/ which this repo tracks-but-ignores as build artifacts (regenerated every
#     build; not source). Outside a git work tree (e.g. the extracted handoff bundle) skip this
#     but keep the artifact check.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -vE '^.{2} (out/|cache/)' || true)"
  if [ -n "$dirty" ]; then
    reasons="${reasons:+$reasons | }working tree not clean (analysis would not match committed source): $(echo "$dirty" | head -3 | tr '\n' ';')"
  fi
else
  echo "clean-tree-guard: not a git work tree — git-dirty check skipped (artifact check still enforced)"
fi

if [ -n "$reasons" ]; then
  echo "CLEAN-TREE GUARD: CONTAMINATED — $reasons" >&2
  exit 1
fi
echo "CLEAN-TREE GUARD: clean (isolated=$REQUIRE_ISOLATED; tree matches committed source; no mutation artifacts)"
exit 0
