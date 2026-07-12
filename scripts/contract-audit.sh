#!/usr/bin/env bash
# contract-audit.sh — SIXX Vault local defense-in-depth audit (ADR-006 Phase 1).
#
# One command, fixed flags, deterministic order, aggregated reports/, pass/fail exit code.
# Local execution is the source of truth; cloud CI is best-effort (osaka EVM panics — see ADR-006).
#
# Stages (hard gates unless noted):
#   0. env         — pin toolchain (solc 0.8.28, cancun), dummy RPC/etherscan for config resolution
#   1. build       — forge build
#   2. test        — forge test (non-fork)
#   3. coverage    — forge coverage; fail if accounting core < COV_MIN
#   4. invariant   — forge invariant suite (value non-creation / shares / non-custody / monotonicity)
#   5. echidna     — property-based fuzzing (deep search)
#   6. slither     — baseline-diff; fail on NEW High/Medium
#   7. aderyn      — machine-judged High/Medium gate vs triaged baseline (hard); abnormal exit → WARN/FAIL
#   8. mutation    — opt-in (--mutation); mutation score + surviving mutants (soft unless MUTATION_MIN set)
#
# Usage:
#   ./scripts/contract-audit.sh                 # full local audit (stages 1-7)
#   ./scripts/contract-audit.sh --mutation      # also run mutation testing (slow)
#   ./scripts/contract-audit.sh --fork          # also run fork suites (needs real RPC in .env)
#   ./scripts/contract-audit.sh --quick         # shorter fuzz/echidna budgets
#   ./scripts/contract-audit.sh --update-slither-baseline   # re-freeze slither allowlist after triage
#
# Tunables (env): COV_MIN (default 85), COV_TARGET (default src/core/SIXXVault.sol),
#   ECHIDNA_LIMIT (default 50000), ADERYN_HIGH_BASELINE (default 1 — triaged FPs),
#   ADERYN_MED_BASELINE (default 0), MUTATION_MIN (unset=report only),
#   MUTATION_TARGET (default src/core/SIXXVault.sol).

set -uo pipefail

# ─── Locate repo root ─────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ─── Options ──────────────────────────────────────────────────
RUN_MUTATION=0
RUN_FORK=0
RUN_HALMOS=0
QUICK=0
UPDATE_SLITHER_BASELINE=0
for arg in "$@"; do
  case "$arg" in
    --mutation) RUN_MUTATION=1 ;;
    --fork)     RUN_FORK=1 ;;
    --halmos)   RUN_HALMOS=1 ;;
    --quick)    QUICK=1 ;;
    --update-slither-baseline) UPDATE_SLITHER_BASELINE=1 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

# ─── Tunables ─────────────────────────────────────────────────
COV_MIN="${COV_MIN:-85}"
COV_TARGET="${COV_TARGET:-src/core/SIXXVault.sol}"
ECHIDNA_LIMIT="${ECHIDNA_LIMIT:-50000}"
# P-02: aderyn High/Medium baseline = count of KNOWN, triaged false positives that the
#   gate tolerates (see audit/ADERYN_TRIAGE.md). Anything above these counts fails the build.
ADERYN_HIGH_BASELINE="${ADERYN_HIGH_BASELINE:-1}"
ADERYN_MED_BASELINE="${ADERYN_MED_BASELINE:-0}"
# P-02 (3rd review): aderyn 0.6.8 is validated exit=0 in the reference toolchain, but is
#   known to panic (exit=101) on some platforms/inputs. Default = crash is a hard FAIL (a
#   crashed run is NEVER a clean pass). Set ADERYN_ADVISORY=1 in an environment where aderyn
#   is known-flaky to downgrade a crash to a loud WARN (manual review; Slither stays the
#   PRIMARY, authoritative static-analysis gate).
ADERYN_ADVISORY="${ADERYN_ADVISORY:-0}"
MUTATION_TARGET="${MUTATION_TARGET:-src/core/SIXXVault.sol}"
if [ "$QUICK" = "1" ]; then ECHIDNA_LIMIT=5000; fi

REPORTS="$REPO_ROOT/reports"
rm -rf "$REPORTS"; mkdir -p "$REPORTS"
SUMMARY="$REPORTS/summary.md"

# ─── Stage 0: environment ─────────────────────────────────────
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
# cancun is required — the default (osaka) panics under this foundry build (ADR-006).
export FOUNDRY_EVM_VERSION="${FOUNDRY_EVM_VERSION:-cancun}"
# Dummy values so foundry.toml [rpc_endpoints]/[etherscan] resolve for non-fork runs.
export ETH_RPC_URL="${ETH_RPC_URL:-https://eth.invalid}"
export ARB_RPC_URL="${ARB_RPC_URL:-https://arb.invalid}"
export BNB_RPC_URL="${BNB_RPC_URL:-https://bnb.invalid}"
export ETH_SEPOLIA_RPC_URL="${ETH_SEPOLIA_RPC_URL:-x}"
export ARB_SEPOLIA_RPC_URL="${ARB_SEPOLIA_RPC_URL:-x}"
export BNB_TESTNET_RPC_URL="${BNB_TESTNET_RPC_URL:-x}"
export ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-dummy}"
export ARBISCAN_API_KEY="${ARBISCAN_API_KEY:-dummy}"
export BSCSCAN_API_KEY="${BSCSCAN_API_KEY:-dummy}"
export ETH_SEPOLIA_ETHERSCAN_API_KEY="${ETH_SEPOLIA_ETHERSCAN_API_KEY:-dummy}"
# Load a real .env last (fork RPCs, real keys) if present — overrides dummies.
if [ -f "$REPO_ROOT/.env" ]; then set -a; . "$REPO_ROOT/.env"; set +a; fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "MISSING TOOL: $1"; return 1; }; }

# ─── Result tracking ──────────────────────────────────────────
declare -a RESULTS
FAILED=0
WARNED=0
record() { # name status detail
  RESULTS+=("$1|$2|$3")
  [ "$2" = "FAIL" ] && FAILED=1
  # P-02 (3rd review): a WARN must not read as a clean pass — track it so the OVERALL
  #   line surfaces "PASS WITH WARNINGS (manual review)" rather than a bare "PASS ✅".
  [ "$2" = "WARN" ] && WARNED=1
  printf '  → %s: %s %s\n' "$1" "$2" "$3"
}
banner() { echo; echo "════════════════════════════════════════════"; echo "▶ $1"; echo "════════════════════════════════════════════"; }

# ─── solc pin ─────────────────────────────────────────────────
banner "Stage 0 — environment (solc 0.8.28 / evm=$FOUNDRY_EVM_VERSION)"
if need solc-select; then
  solc-select install 0.8.28 >/dev/null 2>&1 || true
  solc-select use 0.8.28 >/dev/null 2>&1 || true
fi
solc --version 2>&1 | tail -1 || true
forge --version 2>&1 | head -1 || true

# ─── Stage 0b: on-chain guard regression (safety mechanism) ───
# Presses the smoke-detector's test button every run: proves the PreToolUse guard still
# BLOCKS cast send / forge script --broadcast (exit 2) via the real stdin JSON payload
# (and legacy env), so the on-chain block can't silently break again. Pure bash — no forge.
banner "Stage 0b — on-chain guard regression"
GUARD_TEST="$REPO_ROOT/.claude/hooks/guard-dangerous.test.sh"
if [ -f "$GUARD_TEST" ]; then
  if bash "$GUARD_TEST" > "$REPORTS/guard.log" 2>&1; then
    record "guard" "PASS" "cast send/broadcast blocked; benign allowed (stdin+env+schema canary)"
  else
    record "guard" "FAIL" "(on-chain guard broken — see reports/guard.log)"
    tail -20 "$REPORTS/guard.log"
  fi
else
  # No .claude/ (e.g. the standalone audit handoff bundle) — harness-local guard not present.
  record "guard" "SKIP" "(.claude/hooks/guard-dangerous.test.sh not present — harness-local)"
fi

# ─── Stage 0c: measurement-tooling regression (S0-3) ──────────
# Presses the test button on the MEASURING instruments: proves (a) clean-tree-guard FAILS
# on a dirty/mutated tree and PASSES clean, and (b) mutation-test.sh ABORTS on a broken
# classifier invocation (regex crash / 0-match) instead of faking the score. Blocks a 3rd
# recurrence of the false-kill / analysis-contamination classes. Pure bash (fake forge).
banner "Stage 0c — measurement-tooling regression (mutation false-kill + tree contamination)"
MEAS_TEST="$REPO_ROOT/scripts/measurement-guard.test.sh"
if [ -f "$MEAS_TEST" ]; then
  if bash "$MEAS_TEST" > "$REPORTS/measurement-guard.log" 2>&1; then
    record "measurement-guard" "PASS" "clean-tree + mutation-canary regressions green"
  else
    record "measurement-guard" "FAIL" "(a measurement guard regressed — see reports/measurement-guard.log)"
    tail -30 "$REPORTS/measurement-guard.log"
  fi
else
  record "measurement-guard" "SKIP" "(scripts/measurement-guard.test.sh not present)"
fi

# ─── Stage 0a: clean-tree guard (analysis-contamination prevention) ───
# S0-2 (2026-07-12): NEVER run build/tests/static-analysis on a tree that still has a
# Gambit mutant swapped into src/ or leftover mutation artifacts (gambit_out/, mutants/).
# A mutated contract makes Slither/Aderyn/forge analyse code that is NOT the committed
# source, silently corrupting every finding. This is a HARD gate: exit != 0 → FAIL, and
# we refuse to proceed. Not swallowed (no `|| true`).
banner "Stage 0a — clean-tree guard (no dirty src / mutation artifacts before analysis)"
if bash "$REPO_ROOT/scripts/clean-tree-guard.sh" > "$REPORTS/clean-tree.log" 2>&1; then
  record "clean-tree" "PASS" "src/ matches committed source; no mutation artifacts"
else
  record "clean-tree" "FAIL" "(contaminated tree — refusing to analyse; see reports/clean-tree.log)"
  cat "$REPORTS/clean-tree.log"
  echo "Clean-tree guard tripped — commit/stash src changes and remove gambit_out/ (mutants), then re-run."
fi

# ─── Stage 1: build ───────────────────────────────────────────
# Gated on FAILED so a tripped clean-tree guard (Stage 0a) aborts BEFORE build/analysis.
if [ "$FAILED" = "0" ]; then
banner "Stage 1 — forge build"
if forge build > "$REPORTS/build.log" 2>&1; then
  record "build" "PASS" ""
else
  record "build" "FAIL" "(see reports/build.log)"
  echo "Build failed — aborting remaining stages."
  tail -20 "$REPORTS/build.log"
  # write summary and exit
fi
fi

# Only continue if build passed
if [ "$FAILED" = "0" ]; then

  # ─── Stage 2: non-fork tests ────────────────────────────────
  banner "Stage 2 — forge test (non-fork)"
  # Exclude fork suites and the halmos symbolic file (that runs under `halmos`, not forge).
  if forge test --no-match-contract "Fork" --no-match-path "test/halmos/*" > "$REPORTS/test.log" 2>&1; then
    passline="$(grep -E 'tests passed|test suites' "$REPORTS/test.log" | tail -1)"
    record "test" "PASS" "$passline"
  else
    record "test" "FAIL" "(see reports/test.log)"
    tail -25 "$REPORTS/test.log"
  fi

  # ─── Stage 3: coverage ──────────────────────────────────────
  banner "Stage 3 — forge coverage (gate: $COV_TARGET ≥ ${COV_MIN}% lines)"
  forge coverage --no-match-contract "Fork" --no-match-path "test/halmos/*" \
    --no-match-coverage "(test/|script/)" \
    --report summary > "$REPORTS/coverage.txt" 2>&1 || true
  cov_pct="$(python3 - "$REPORTS/coverage.txt" "$COV_TARGET" <<'PY'
import sys,re
path,target=sys.argv[1],sys.argv[2]
pct=None
for line in open(path):
    if target in line:
        m=re.search(r'([\d.]+)%\s*\(\d+/\d+\)', line)  # first %Lines column
        if m: pct=float(m.group(1))
        break
print(pct if pct is not None else -1)
PY
)"
  grep -E 'File|core/|adapters/|Total' "$REPORTS/coverage.txt" 2>/dev/null | head -20 || true
  if [ "$(python3 -c "print(1 if float('$cov_pct')>=$COV_MIN else 0)" 2>/dev/null)" = "1" ]; then
    record "coverage" "PASS" "$COV_TARGET lines=${cov_pct}% (≥${COV_MIN}%)"
  else
    record "coverage" "FAIL" "$COV_TARGET lines=${cov_pct}% (<${COV_MIN}%)"
  fi

  # ─── Stage 4: invariant suite ───────────────────────────────
  banner "Stage 4 — forge invariant (accounting safety properties)"
  if forge test --match-path "test/invariant/*" -vv > "$REPORTS/invariant.log" 2>&1; then
    invline="$(grep -E 'tests passed|passed;' "$REPORTS/invariant.log" | tail -1)"
    record "invariant" "PASS" "$invline"
  else
    record "invariant" "FAIL" "(see reports/invariant.log)"
    tail -25 "$REPORTS/invariant.log"
  fi

  # ─── Stage 5: echidna (property fuzzing — both harnesses) ───
  banner "Stage 5 — echidna property fuzzing (limit=$ECHIDNA_LIMIT)"
  if need echidna; then
    # SIXXVaultEchidna = accounting core; StateTransitionEchidna = state×fault cross-check.
    ECH_TOTAL=0; ECH_FAIL=0
    : > "$REPORTS/echidna.log"
    for pair in "test/echidna/SIXXVaultEchidna.sol:SIXXVaultEchidna" \
                "test/echidna/StateTransitionEchidna.sol:StateTransitionEchidna"; do
      f="${pair%%:*}"; c="${pair##*:}"
      echo "── $c ──" >> "$REPORTS/echidna.log"
      if echidna "$f" --contract "$c" --config echidna.yaml \
           --test-limit "$ECHIDNA_LIMIT" --format text >> "$REPORTS/echidna.log" 2>&1; then
        if grep -q "falsified\|FAILED" "$REPORTS/echidna.log"; then ECH_FAIL=1; fi
      else
        ECH_FAIL=1
      fi
    done
    ECH_TOTAL="$(grep -c ': passing' "$REPORTS/echidna.log" 2>/dev/null || echo 0)"
    if [ "$ECH_FAIL" = "0" ]; then
      record "echidna" "PASS" "${ECH_TOTAL} properties passing (2 harnesses: core + state×fault)"
    else
      record "echidna" "FAIL" "(property falsified / error — see reports/echidna.log)"
      tail -15 "$REPORTS/echidna.log"
    fi
  else
    record "echidna" "SKIP" "(echidna not installed)"
  fi

  # ─── Stage 6: slither (baseline diff) ───────────────────────
  banner "Stage 6 — slither (new High/Medium gate)"
  if need slither; then
    slither . --filter-paths "lib/|test/|script/" \
      --json "$REPORTS/slither-current.json" > "$REPORTS/slither.log" 2>&1 || true
    if [ "$UPDATE_SLITHER_BASELINE" = "1" ]; then
      cp "$REPORTS/slither-current.json" "$REPO_ROOT/audit/slither-baseline.json"
      record "slither" "PASS" "(baseline updated — re-freeze)"
    elif [ -f "$REPORTS/slither-current.json" ]; then
      if python3 audit/slither-check.py --current "$REPORTS/slither-current.json" \
           --baseline audit/slither-baseline.json --out "$REPORTS/slither-new-findings.txt"; then
        record "slither" "PASS" "no new High/Medium vs baseline"
      else
        record "slither" "FAIL" "(new High/Medium — see reports/slither-new-findings.txt)"
      fi
    else
      record "slither" "FAIL" "(slither produced no JSON — see reports/slither.log)"
    fi
  else
    record "slither" "SKIP" "(slither not installed)"
  fi

  # ─── Stage 7: aderyn (SECONDARY machine-judged High/Medium gate) ──────
  # P-02 (2nd review): a real gate, not a soft "report generated". Aderyn's own
  #   "Issue Summary" table is parsed for High/Medium counts and compared to a
  #   TRIAGED baseline (known false positives, documented in audit/ADERYN_TRIAGE.md).
  #
  #   Role: Slither (Stage 6) is the PRIMARY static-analysis gate (full baseline diff +
  #   dangerous-detector coverage). Aderyn is a SECONDARY cross-check whose one triaged
  #   High-1 (reentrancy) is confirmed a false positive against Slither (no reentrancy-eth;
  #   see audit/ADERYN_TRIAGE.md §cross-check).
  #
  #   Crash-safety guarantee (SHIN 2nd/3rd review): a PASS is emitted ONLY when ALL of
  #   (a) a report file exists, (b) it contains a parseable "Issue Summary" table,
  #   (c) High/Med are within the triaged baseline, AND (d) aderyn exited 0. A crashed /
  #   incomplete run (no report / no summary / exit!=0) is a hard FAIL by default — NEVER a
  #   clean pass — and its High/Med counts are never a PASS basis. ADERYN_ADVISORY=1
  #   downgrades a crash to a WARN that still flags MANUAL REVIEW and surfaces "PASS WITH
  #   WARNINGS" in the summary (for environments where aderyn 0.6.8 panics, exit=101).
  #   Validated working version: aderyn 0.6.8 (deterministic exit=0 in the reference toolchain).
  banner "Stage 7 — aderyn (secondary High/Medium gate vs triaged baseline)"
  if need aderyn; then
    aderyn . -o "$REPORTS/aderyn-report.md" > "$REPORTS/aderyn.log" 2>&1
    arc=$?
    # P-02 (3rd review): a crash/incomplete run is a hard FAIL by default (never a clean
    #   pass); ADERYN_ADVISORY=1 downgrades it to a WARN that still flags MANUAL REVIEW.
    if [ "$ADERYN_ADVISORY" = "1" ]; then
      crash_status="WARN"; crash_note="ADVISORY — MANUAL REVIEW required; Slither is authoritative"
    else
      crash_status="FAIL"; crash_note="crash blocks the build; set ADERYN_ADVISORY=1 to downgrade to manual-review"
    fi
    if [ ! -f "$REPORTS/aderyn-report.md" ]; then
      record "aderyn" "$crash_status" "(no report — aderyn exit=$arc, crashed; $crash_note)"
    else
      # Machine-judge: the parser emits "FOUND h m" only if a real Issue Summary table
      # was present; "MISSING 0 0" means the report is malformed/incomplete (e.g. a run
      # that crashed mid-write) and must NOT be treated as a clean zero-finding PASS.
      ad_parse="$(python3 - "$REPORTS/aderyn-report.md" <<'PY'
import sys, re
high = med = 0
in_summary = found = False
for line in open(sys.argv[1], encoding='utf-8'):
    s = line.strip().lower()
    if s.startswith('## issue summary'):
        in_summary = found = True; continue
    if in_summary:
        if line.startswith('#'):  # next top-level/section header → summary ended
            break
        m = re.match(r'\|\s*(high|medium)\s*\|\s*(\d+)\s*\|', s)
        if m:
            if m.group(1) == 'high': high = int(m.group(2))
            else: med = int(m.group(2))
print(('FOUND' if found else 'MISSING'), high, med)
PY
)"
      ad_found="$(echo "$ad_parse" | awk '{print $1}')"
      AD_HIGH="$(echo "$ad_parse" | awk '{print $2+0}')"
      AD_MED="$(echo "$ad_parse" | awk '{print $3+0}')"
      detail="High=${AD_HIGH}(≤${ADERYN_HIGH_BASELINE}) Med=${AD_MED}(≤${ADERYN_MED_BASELINE}) exit=${arc}"
      if [ "$ad_found" != "FOUND" ]; then
        # Report present but no parseable Issue Summary — incomplete/crashed run.
        record "aderyn" "$crash_status" "(report has no Issue Summary — incomplete/crashed run; exit=$arc; $crash_note)"
      elif [ "$AD_HIGH" -gt "$ADERYN_HIGH_BASELINE" ] || [ "$AD_MED" -gt "$ADERYN_MED_BASELINE" ]; then
        record "aderyn" "FAIL" "(NEW High/Medium beyond triaged baseline — $detail; see audit/ADERYN_TRIAGE.md)"
      elif [ "$arc" -ne 0 ]; then
        # Parsed a clean report but aderyn still exited non-zero (e.g. exit=101 panic on
        # teardown) — NOT a clean pass. FAIL by default; WARN + manual-review in advisory mode.
        record "aderyn" "$crash_status" "(aderyn exit=$arc — crashed despite a parseable report; $detail; $crash_note)"
      else
        record "aderyn" "PASS" "no new High/Medium vs triaged baseline ($detail)"
      fi
    fi
  else
    record "aderyn" "SKIP" "(aderyn not installed)"
  fi

  # ─── Stage 8: mutation testing (opt-in) ─────────────────────
  if [ "$RUN_MUTATION" = "1" ]; then
    banner "Stage 8 — mutation testing ($MUTATION_TARGET)"
    if [ -x "$REPO_ROOT/scripts/mutation-test.sh" ]; then
      if "$REPO_ROOT/scripts/mutation-test.sh" "$MUTATION_TARGET" > "$REPORTS/mutation.log" 2>&1; then
        score="$(grep -iE 'mutation score' "$REPORTS/mutation.log" | tail -1)"
        record "mutation" "PASS" "$score"
      else
        record "mutation" "WARN" "(see reports/mutation.log — score below MUTATION_MIN or tool error)"
      fi
    else
      record "mutation" "SKIP" "(scripts/mutation-test.sh missing)"
    fi
  fi

  # ─── Stage 8b: halmos symbolic pilot (opt-in) ───────────────
  if [ "$RUN_HALMOS" = "1" ]; then
    banner "Stage 8b — halmos symbolic pilot (accounting core)"
    HALMOS_BIN=""
    if [ -x "$REPO_ROOT/.venv-audit/bin/halmos" ]; then HALMOS_BIN="$REPO_ROOT/.venv-audit/bin/halmos";
    elif command -v halmos >/dev/null 2>&1; then HALMOS_BIN="halmos"; fi
    if [ -n "$HALMOS_BIN" ]; then
      # halmos needs AST in artifacts; plain `forge build` (earlier stages) strips it,
      # so clean first and let halmos control the build.
      forge clean >/dev/null 2>&1 || true
      if "$HALMOS_BIN" --function check_ --contract SIXXVaultSymbolic \
           --solver-timeout-assertion 30000 > "$REPORTS/halmos.log" 2>&1; then
        record "halmos" "PASS" "symbolic property verified"
      else
        record "halmos" "WARN" "(counterexample or solver timeout — see reports/halmos.log)"
      fi
    else
      record "halmos" "SKIP" "(halmos not installed — pip install halmos in .venv-audit)"
    fi
  fi

  # ─── Stage 9: fork suites (opt-in) ──────────────────────────
  if [ "$RUN_FORK" = "1" ]; then
    banner "Stage 9 — fork suites (needs real RPC)"
    forge test --match-contract "Fork" > "$REPORTS/fork.log" 2>&1 \
      && record "fork" "PASS" "" || record "fork" "WARN" "(fork run failed — check RPC/.env)"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────
banner "SUMMARY"
{
  echo "# SIXX Vault — contract-audit report"
  echo
  echo "evm=$FOUNDRY_EVM_VERSION · solc=0.8.28 · commit=$(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
  echo
  echo "| stage | result | detail |"
  echo "|---|---|---|"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r n s d <<< "$r"
    echo "| $n | $s | $d |"
  done
  echo
  # P-02 (3rd review): a WARN (e.g. an advisory aderyn crash) must NOT read as a clean
  #   pass — surface it distinctly so a crashed run is never a silent "green".
  if [ "$FAILED" != "0" ]; then
    echo "**OVERALL: FAIL ❌**"
  elif [ "$WARNED" != "0" ]; then
    echo "**OVERALL: PASS WITH WARNINGS ⚠️ — manual review required (see WARN rows)**"
  else
    echo "**OVERALL: PASS ✅**"
  fi
} | tee "$SUMMARY"

echo
if [ "$FAILED" = "0" ]; then
  echo "contract-audit: PASS"
  exit 0
else
  echo "contract-audit: FAIL"
  exit 1
fi
