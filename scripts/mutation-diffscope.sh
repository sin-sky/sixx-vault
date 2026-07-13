#!/usr/bin/env bash
# mutation-diffscope.sh — M-4 diff-line mutation for the ADR-007 exit path.
#
# Unlike scripts/mutation-test.sh (random whole-file sample), this restricts mutants to the
# lines the ADR-007 pro-rata-exit commit (9c7c9e7) actually changed in src/core/SIXXVault.sol
# — withdraw/redeem bodies + _exitRealize + _completeExit + the F-2/F-3 helper edits. Every
# such mutant is run against the full non-fork suite; a SURVIVOR is an exit-path change no
# test caught. Original source is always restored (trap).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT"
TARGET="src/core/SIXXVault.sol"
OUTDIR="$REPO_ROOT/gambit_diffscope"
REPORTS="$REPO_ROOT/reports/mutation"; mkdir -p "$REPORTS"
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
export FOUNDRY_EVM_VERSION="${FOUNDRY_EVM_VERSION:-cancun}"
export FOUNDRY_FUZZ_RUNS="${FOUNDRY_FUZZ_RUNS:-64}"
export FOUNDRY_INVARIANT_RUNS="${FOUNDRY_INVARIANT_RUNS:-16}"
export ETH_RPC_URL="${ETH_RPC_URL:-x}" ARB_RPC_URL="${ARB_RPC_URL:-x}" BNB_RPC_URL="${BNB_RPC_URL:-x}"
export ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-d}" ARBISCAN_API_KEY="${ARBISCAN_API_KEY:-d}" BSCSCAN_API_KEY="${BSCSCAN_API_KEY:-d}"
command -v gambit >/dev/null 2>&1 || { echo "MISSING TOOL: gambit"; exit 3; }

# Changed exit-path lines in the CURRENT file (== committed tip, clean tree), from 9c7c9e7.
# Ranges: start:count. count blank/1 => single line; count 0 (pure deletion) omitted.
RANGES="144:7 155:9 170:7 192:1 313:57 371:14 8:1 647:1"

BACKUP="$(mktemp)"; cp "$TARGET" "$BACKUP"
restore(){ cp "$BACKUP" "$TARGET"; rm -f "$BACKUP"; }
trap restore EXIT INT TERM

echo "==> Pre-flight: unmutated suite must pass…"
PF="$REPORTS/diffscope-preflight.log"
if ! forge test --no-match-contract "Fork" > "$PF" 2>&1; then
  echo "PREFLIGHT FAIL"; tail -20 "$PF"; exit 4; fi
PF_PASSED="$(grep -oE "[0-9]+ tests? passed" "$PF" | grep -oE "^[0-9]+" | tail -1)"
[ "${PF_PASSED:-0}" -gt 0 ] || { echo "PREFLIGHT FAIL: 0 tests"; exit 4; }
echo "==> Pre-flight OK: $PF_PASSED tests pass."

echo "==> Generating full mutant pool for $TARGET…"
rm -rf "$OUTDIR"
gambit mutate --filename "$TARGET" --sourceroot . --solc solc --skip_validate \
  --num_mutants 4000 --seed 0 \
  --solc_remappings "@openzeppelin/=lib/openzeppelin-contracts/" "forge-std/=lib/forge-std/src/" \
  --outdir "$OUTDIR" > "$REPORTS/diffscope-gambit.log" 2>&1 || { echo "gambit failed"; tail "$REPORTS/diffscope-gambit.log"; exit 3; }

# Filter to mutants whose diff target line is in a changed range.
IDS="$(python3 - "$OUTDIR/gambit_results.json" <<PY
import json,re,sys
data=json.load(open(sys.argv[1]))
ranges=[(int(a),int(a)+ (int(c) if c else 1)-1) for a,c in
        (r.split(':') for r in "$RANGES".split())]
def inrange(ln): return any(lo<=ln<=hi for lo,hi in ranges)
out=[]
for m in data:
    mm=re.search(r'@@ -(\d+)', m['diff'])
    if mm and inrange(int(mm.group(1))): out.append(m['id'])
print(' '.join(out))
PY
)"
NIDS=$(echo $IDS | wc -w)
echo "==> $NIDS mutants land on the changed exit-path lines. Running suite per mutant…"

KILLED=0; SURVIVED=0; SURV="$REPORTS/diffscope-survivors.txt"; : > "$SURV"
for id in $IDS; do
  MUT="$OUTDIR/mutants/$id/$TARGET"; [ -f "$MUT" ] || continue
  cp "$MUT" "$TARGET"
  if forge test --no-match-contract "Fork" -q > /dev/null 2>&1; then
    SURVIVED=$((SURVIVED+1))
    desc="$(python3 -c "import json;m=[x for x in json.load(open('$OUTDIR/gambit_results.json')) if x['id']=='$id'][0];print(m['description'])" 2>/dev/null)"
    dh="$(python3 -c "import json;m=[x for x in json.load(open('$OUTDIR/gambit_results.json')) if x['id']=='$id'][0];print(' '.join(l for l in m['diff'].splitlines() if l[:1] in '+-' and l[:3] not in ('+++','---'))[:160])" 2>/dev/null)"
    echo "SURVIVED #$id [$desc] :: $dh" | tee -a "$SURV"
  else KILLED=$((KILLED+1)); fi
  cp "$BACKUP" "$TARGET"
done
TOTAL=$((KILLED+SURVIVED))
SCORE="$([ $TOTAL -gt 0 ] && python3 -c "print(round($KILLED/$TOTAL*100,1))" || echo 0.0)"
{
  echo "# M-4 diff-line mutation — $TARGET (ADR-007 exit path, commit 9c7c9e7)"
  echo; echo "- changed-line mutants: $TOTAL (killed $KILLED / survived $SURVIVED)"
  echo "- **mutation score: ${SCORE}%**"
  echo "- fuzz_runs=$FOUNDRY_FUZZ_RUNS invariant_runs=$FOUNDRY_INVARIANT_RUNS (reduced for speed)"; echo
  if [ "$SURVIVED" -gt 0 ]; then echo "## Survivors (exit-path change no test caught)"; echo '```'; cat "$SURV"; echo '```'
  else echo "All changed-line mutants killed — no gaps on the ADR-007 exit path."; fi
} > "$REPORTS/diffscope-report.md"
echo "==> DONE score=${SCORE}% killed=$KILLED survived=$SURVIVED  report: reports/mutation/diffscope-report.md"
