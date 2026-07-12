#!/usr/bin/env bash
# mutation-test.sh — mutation testing for the SIXX Vault accounting core (ADR-006 Phase 1).
#
# Quantifies how many injected faults (mutants) the test suite actually catches ("kills").
# Surviving mutants = holes in the tests: a changed contract that no test noticed.
#
# Engine: Gambit (Certora) generates mutants; this harness applies each one, runs the
# non-fork forge suite, and classifies killed vs. survived. The original source is ALWAYS
# restored (trap on EXIT), so a run never leaves a mutated contract behind.
#
# Usage:   ./scripts/mutation-test.sh [target.sol]
# Env:     MUTATION_N (downsample, default 40), MUTATION_SEED (default 0),
#          MUTATION_MIN (fail if score < this %, default unset = report only),
#          MUTATION_MATCH (forge test filter, default non-fork suite)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGET="${1:-src/core/SIXXVault.sol}"
N="${MUTATION_N:-40}"
SEED="${MUTATION_SEED:-0}"
OUTDIR="$REPO_ROOT/gambit_out"
REPORTS="$REPO_ROOT/reports/mutation"
mkdir -p "$REPORTS"

export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
export FOUNDRY_EVM_VERSION="${FOUNDRY_EVM_VERSION:-cancun}"
# Shrink fuzz/invariant budgets so per-mutant runtime stays reasonable while still
# exercising those paths (a mutant only caught by an invariant should still die).
export FOUNDRY_FUZZ_RUNS="${FOUNDRY_FUZZ_RUNS:-64}"
export FOUNDRY_INVARIANT_RUNS="${FOUNDRY_INVARIANT_RUNS:-16}"
export ETH_RPC_URL="${ETH_RPC_URL:-x}" ARB_RPC_URL="${ARB_RPC_URL:-x}" BNB_RPC_URL="${BNB_RPC_URL:-x}"
export ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-d}" ARBISCAN_API_KEY="${ARBISCAN_API_KEY:-d}" BSCSCAN_API_KEY="${BSCSCAN_API_KEY:-d}"

command -v gambit >/dev/null 2>&1 || { echo "MISSING TOOL: gambit"; exit 3; }

# ─── Always restore the original source ───────────────────────
BACKUP="$(mktemp)"
cp "$TARGET" "$BACKUP"
restore() { cp "$BACKUP" "$TARGET"; rm -f "$BACKUP"; }
trap restore EXIT INT TERM

# ─── Pre-flight canary (S0-3, 2026-07-12): the classifier invocation MUST be sound ───
# Root-cause fix for the `--match-contract '*'` false-kill class. The per-mutant classifier
# is "did `forge test <filters>` pass?". If that invocation is broken, every mutant is
# mis-classified and the score is fiction:
#   • a regex error (e.g. MUTATION_MATCH='*') makes forge exit non-zero  → every mutant
#     looks KILLED (false ~100%);
#   • a 0-match filter makes forge exit 0 having run NO tests             → every mutant
#     looks SURVIVED (false ~0%).
# Verify BOTH on the UNMUTATED source before spending time on mutants: (a) the exact
# invocation exits 0, AND (b) it actually ran > 0 tests. Abort (exit 4) if not — refuse to
# emit fake numbers. NOT run with -q, so the "N tests passed" summary is parseable.
echo "==> Pre-flight: verifying the classifier invocation on UNMUTATED source…"
PF="$REPORTS/preflight.log"
if ! forge test --no-match-contract "Fork" ${MUTATION_MATCH:+--match-contract "$MUTATION_MATCH"} > "$PF" 2>&1; then
  echo "PREFLIGHT FAIL: the suite invocation does NOT pass on the unmutated source."
  echo "  A broken invocation (e.g. MUTATION_MATCH='*' regex error) mis-classifies every"
  echo "  mutant as killed (false ~100%). Fix the invocation — refusing to produce fake numbers."
  tail -20 "$PF"; exit 4
fi
PF_PASSED="$(grep -oE "[0-9]+ tests? passed" "$PF" | grep -oE "^[0-9]+" | tail -1)"
if [ -z "$PF_PASSED" ] || [ "$PF_PASSED" -eq 0 ]; then
  echo "PREFLIGHT FAIL: the invocation ran 0 tests (0-match filter / silent pass)."
  echo "  Every mutant would falsely 'survive'. Fix MUTATION_MATCH — refusing to produce fake numbers."
  tail -20 "$PF"; exit 4
fi
echo "==> Pre-flight OK: unmutated source passes with $PF_PASSED tests — classifier invocation is sound."

echo "==> Generating mutants for $TARGET (N=$N, seed=$SEED)"
rm -rf "$OUTDIR"
REMAP1="@openzeppelin/=lib/openzeppelin-contracts/"
REMAP2="forge-std/=lib/forge-std/src/"
gambit mutate --filename "$TARGET" --sourceroot . --solc solc --skip_validate \
  --num_mutants "$N" --seed "$SEED" \
  --solc_remappings "$REMAP1" "$REMAP2" \
  --outdir "$OUTDIR" > "$REPORTS/gambit.log" 2>&1 || { echo "gambit failed"; cat "$REPORTS/gambit.log"; exit 3; }

MUTS="$(python3 -c "import json;print(len(json.load(open('$OUTDIR/gambit_results.json'))))" 2>/dev/null || echo 0)"
echo "==> $MUTS mutants generated. Running suite per mutant (this is slow)…"

KILLED=0; SURVIVED=0
SURV_FILE="$REPORTS/survivors.txt"
: > "$SURV_FILE"

# Iterate mutants in id order
IDS="$(python3 -c "import json;[print(m['id']) for m in json.load(open('$OUTDIR/gambit_results.json'))]" 2>/dev/null)"
for id in $IDS; do
  MUT="$OUTDIR/mutants/$id/$TARGET"
  [ -f "$MUT" ] || { echo "  mutant $id: no file, skip"; continue; }
  cp "$MUT" "$TARGET"
  if forge test --no-match-contract "Fork" ${MUTATION_MATCH:+--match-contract "$MUTATION_MATCH"} -q > /dev/null 2>&1; then
    # suite passed on the mutated contract → mutant SURVIVED (test gap)
    SURVIVED=$((SURVIVED+1))
    desc="$(python3 -c "import json;m=[x for x in json.load(open('$OUTDIR/gambit_results.json')) if x['id']=='$id'][0];print(m['description'])" 2>/dev/null)"
    diffhead="$(python3 -c "import json;m=[x for x in json.load(open('$OUTDIR/gambit_results.json')) if x['id']=='$id'][0];print(' '.join(l for l in m['diff'].splitlines() if l.startswith(('+','-')) and not l.startswith(('+++','---')))[:160])" 2>/dev/null)"
    echo "SURVIVED mutant #$id [$desc] :: $diffhead" | tee -a "$SURV_FILE"
  else
    KILLED=$((KILLED+1))
  fi
  cp "$BACKUP" "$TARGET"   # restore between mutants
done

TOTAL=$((KILLED+SURVIVED))
if [ "$TOTAL" -gt 0 ]; then
  SCORE="$(python3 -c "print(round($KILLED/$TOTAL*100,1))")"
else
  SCORE="0.0"
fi

{
  echo "# Mutation testing — $TARGET"
  echo
  echo "- mutants: $TOTAL (killed $KILLED / survived $SURVIVED)"
  echo "- **mutation score: ${SCORE}%**"
  echo "- fuzz_runs=$FOUNDRY_FUZZ_RUNS invariant_runs=$FOUNDRY_INVARIANT_RUNS (reduced for speed)"
  echo
  if [ "$SURVIVED" -gt 0 ]; then
    echo "## Surviving mutants (test gaps — a change no test caught)"
    echo '```'
    cat "$SURV_FILE"
    echo '```'
  else
    echo "All mutants killed — no test gaps in sampled operators."
  fi
} > "$REPORTS/mutation-report.md"

echo
echo "==> mutation score: ${SCORE}%  (killed $KILLED / survived $SURVIVED)"
echo "==> report: reports/mutation/mutation-report.md"

if [ -n "${MUTATION_MIN:-}" ]; then
  if [ "$(python3 -c "print(1 if $SCORE>=${MUTATION_MIN} else 0)")" = "1" ]; then
    echo "mutation score ${SCORE}% >= MUTATION_MIN ${MUTATION_MIN}% → PASS"; exit 0
  else
    echo "mutation score ${SCORE}% < MUTATION_MIN ${MUTATION_MIN}% → FAIL"; exit 1
  fi
fi
exit 0
