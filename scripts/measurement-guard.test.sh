#!/usr/bin/env bash
# measurement-guard.test.sh — regression tests for the audit MEASUREMENT tooling (S0-3).
#
# Two classes of "the measuring instrument lied" bugs were found on 2026-07-12 and must
# never silently return a 3rd time:
#   (1) mutation FALSE-KILL: a broken classifier invocation (`--match-contract '*'` regex
#       error, or a 0-match filter) mis-classified every mutant, faking the score.
#   (2) static-analysis CONTAMINATION: Slither/Aderyn read a tree with a Gambit mutant
#       still swapped into src/, inventing a phantom High.
#
# This proves the guards that now stop both:
#   A. clean-tree-guard.sh FAILS on a dirty src/ tree.
#   B. clean-tree-guard.sh FAILS when mutation artifacts (gambit_out/) are present.
#   C. clean-tree-guard.sh PASSES on a clean committed tree.
#   D. mutation-test.sh ABORTS (exit 4) when the classifier invocation crashes (regex error).
#   E. mutation-test.sh ABORTS (exit 4) when the classifier runs 0 tests (0-match filter).
#   F. mutation-test.sh PASSES its pre-flight on a SOUND invocation (then stops at gambit).
#
# Pure/hermetic: D–F use a fake `forge`/`gambit` via a fake $HOME, so no compilation runs.
# Exit 0 = all pass. Exit 1 = a regression (a guard failed to fire, or fired wrongly).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/clean-tree-guard.sh"
MUT="$REPO_ROOT/scripts/mutation-test.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()   { echo "  PASS: $1"; }
bad()  { echo "  FAIL: $1"; fails=$((fails+1)); }

# ── Fixtures A–C: clean-tree-guard against throwaway git repos ────────────────
mkrepo() { # $1=dir
  mkdir -p "$1/src"
  git -C "$1" init -q
  git -C "$1" config user.email t@t.t; git -C "$1" config user.name t
  echo "contract C {}" > "$1/src/C.sol"
  git -C "$1" add -A; git -C "$1" commit -qm init
}

echo "== A: dirty src/ → guard FAIL =="
RA="$TMP/dirty"; mkrepo "$RA"
echo "// mutated" >> "$RA/src/C.sol"   # uncommitted change (simulates a leftover mutant)
if bash "$GUARD" "$RA" >/dev/null 2>&1; then bad "guard passed on a dirty src/ tree"; else ok "guard failed on dirty src/"; fi

echo "== B: mutation artifacts (gambit_out/) → guard FAIL =="
RB="$TMP/arts"; mkrepo "$RB"
mkdir -p "$RB/gambit_out/mutants/1"
if bash "$GUARD" "$RB" >/dev/null 2>&1; then bad "guard passed with gambit_out/ present"; else ok "guard failed on mutation artifacts"; fi

echo "== C: clean committed tree → guard PASS =="
RC="$TMP/clean"; mkrepo "$RC"
if bash "$GUARD" "$RC" >/dev/null 2>&1; then ok "guard passed on a clean tree"; else bad "guard FAILED on a clean tree (false positive)"; fi

# ── Fixtures D–F: mutation-test.sh pre-flight canary via fake forge/gambit ────
# mutation-test.sh does `export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"`, so a fake
# $HOME lets our fake forge/gambit win resolution without a real compile.
FH="$TMP/fakehome"; mkdir -p "$FH/.foundry/bin" "$FH/.local/bin"
cat > "$FH/.foundry/bin/forge" <<'FORGE'
#!/usr/bin/env bash
case "${FAKE_FORGE_MODE:-ok}" in
  crash) exit 1 ;;                                              # regex error / broken invocation
  zero)  echo "Ran 0 test suites in 1ms: 0 tests passed";  exit 0 ;;   # 0-match silent pass
  *)     echo "Ran 5 test suites in 1s: 123 tests passed"; exit 0 ;;   # sound
esac
FORGE
cat > "$FH/.local/bin/gambit" <<'GAMBIT'
#!/usr/bin/env bash
# After a SOUND pre-flight the harness reaches mutant generation; fail here so the test
# stops without a real mutation run (we only need to prove the canary verdict).
[ "$1" = "mutate" ] && { echo "fake gambit: stop"; exit 3; }
exit 0
GAMBIT
chmod +x "$FH/.foundry/bin/forge" "$FH/.local/bin/gambit"

run_mut() { # $1=FAKE_FORGE_MODE ; echoes exit code
  HOME="$FH" FAKE_FORGE_MODE="$1" MUTATION_MATCH="" \
    bash "$MUT" src/core/AdapterRegistry.sol > "$TMP/mut.$1.log" 2>&1
  echo $?
}

echo "== D: classifier CRASHES (regex error) → mutation aborts exit 4 =="
code="$(run_mut crash)"
if [ "$code" = "4" ] && grep -q "PREFLIGHT FAIL" "$TMP/mut.crash.log"; then ok "aborted (exit 4) on a crashing invocation"; else bad "did NOT abort on crash (exit=$code) — false-kill class not caught"; fi

echo "== E: classifier runs 0 tests (0-match) → mutation aborts exit 4 =="
code="$(run_mut zero)"
if [ "$code" = "4" ] && grep -q "ran 0 tests" "$TMP/mut.zero.log"; then ok "aborted (exit 4) on a 0-test invocation"; else bad "did NOT abort on 0-test run (exit=$code) — false-survive class not caught"; fi

echo "== F: SOUND invocation → pre-flight PASSES (then stops at fake gambit) =="
code="$(run_mut ok)"
if grep -q "Pre-flight OK" "$TMP/mut.ok.log" && [ "$code" = "3" ]; then ok "pre-flight passed on a sound invocation (stopped at gambit, exit 3)"; else bad "pre-flight mis-fired on a sound invocation (exit=$code) — see $TMP/mut.ok.log"; fi

# ── Fixtures G–K: 2026-07-13 hardening — isolation + concurrent-edit tripwire ──
# These pin the STRUCTURAL fix for the shared-working-tree root cause: measurement may run
# only in a dedicated linked worktree, and src must stay frozen for the whole run.
RUNNER="$REPO_ROOT/scripts/guarded-analysis.sh"

echo "== G: --require-isolated → FAIL in the main tree, PASS in a linked worktree =="
RG="$TMP/isomain"; mkrepo "$RG"
if bash "$GUARD" --require-isolated "$RG" >/dev/null 2>&1; then bad "guard passed --require-isolated in a MAIN tree (should refuse)"; else ok "guard refused --require-isolated in the shared main tree"; fi
WG="$TMP/isowt"
if git -C "$RG" worktree add -q --detach "$WG" >/dev/null 2>&1; then
  if bash "$GUARD" --require-isolated "$WG" >/dev/null 2>&1; then ok "guard passed --require-isolated in a linked worktree"; else bad "guard refused --require-isolated in a legit linked worktree (false positive)"; fi
else
  bad "could not create a linked worktree for the isolation test"
fi

echo "== H: guarded-analysis → exit 5 when the command edits src MID-RUN (concurrent writer) =="
# Command touches a NON-target src file while 'running' — simulates the 2nd session's edit.
out="$(cd "$WG" && GUARDED_ANALYSIS_ROOT="$WG" REQUIRE_ISOLATED_WORKTREE=1 bash "$RUNNER" testH -- bash -c 'echo "// concurrent edit" >> src/C.sol' 2>&1)"; code=$?
if [ "$code" = "5" ] && echo "$out" | grep -q "SOURCE CHANGED MID-RUN"; then ok "detected mid-run src edit and discarded results (exit 5)"; else bad "did NOT catch a mid-run src edit (exit=$code) — concurrent-contamination class not caught"; fi
git -C "$WG" checkout -q -- src 2>/dev/null || true   # undo the simulated edit for later fixtures

echo "== I: guarded-analysis → PASS when src is untouched for the whole run =="
out="$(cd "$WG" && GUARDED_ANALYSIS_ROOT="$WG" REQUIRE_ISOLATED_WORKTREE=1 bash "$RUNNER" testI -- bash -c 'sleep 0; true' 2>&1)"; code=$?
if [ "$code" = "0" ] && echo "$out" | grep -q "tree frozen for the whole run"; then ok "passed when nobody touched src"; else bad "false positive on an untouched tree (exit=$code): $out"; fi

echo "== J: --allow-target excludes the mutated file but STILL catches edits to OTHER files =="
mkdir -p "$WG/src"; echo "contract D {}" > "$WG/src/D.sol"; git -C "$WG" add -A; git -C "$WG" commit -qm addD
# Editing the ALLOWED target only → PASS (mutation harness legitimately mutates its target).
out="$(cd "$WG" && GUARDED_ANALYSIS_ROOT="$WG" REQUIRE_ISOLATED_WORKTREE=1 bash "$RUNNER" testJ1 --allow-target src/C.sol -- bash -c 'echo "//m" >> src/C.sol' 2>&1)"; code=$?
if [ "$code" = "0" ]; then ok "--allow-target ignores an edit to the target file"; else bad "--allow-target wrongly tripped on its own target (exit=$code)"; fi
git -C "$WG" checkout -q -- src 2>/dev/null || true
# Editing a DIFFERENT src file while target is allowed → still exit 5.
out="$(cd "$WG" && GUARDED_ANALYSIS_ROOT="$WG" REQUIRE_ISOLATED_WORKTREE=1 bash "$RUNNER" testJ2 --allow-target src/C.sol -- bash -c 'echo "//x" >> src/D.sol' 2>&1)"; code=$?
if [ "$code" = "5" ]; then ok "--allow-target still catches an edit to a NON-target file (exit 5)"; else bad "--allow-target missed an edit to a non-target file (exit=$code)"; fi
git -C "$WG" checkout -q -- src 2>/dev/null || true

echo "== K: guarded-analysis → exit 6 when the tree is NOT clean/isolated at START =="
out="$(cd "$RG" && GUARDED_ANALYSIS_ROOT="$RG" bash "$RUNNER" testK -- true 2>&1)"; code=$?   # RG is a main tree → not isolated
if [ "$code" = "6" ]; then ok "refused to start on a non-isolated tree (exit 6)"; else bad "ran a measurement on a non-isolated tree (exit=$code)"; fi

echo
if [ "$fails" = "0" ]; then echo "measurement-guard: ALL PASS"; exit 0; else echo "measurement-guard: $fails FAILED"; exit 1; fi
