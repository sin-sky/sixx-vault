#!/usr/bin/env bash
# verify-audit-toolchain.sh — assert the full contract-audit toolchain is present
# and pinned to the expected versions (determinism check).
#
# Run this on BOTH a local (macOS) machine and inside the Codespace, then diff the
# tables: any row that is PASS locally but MISSING/here differs = an audit item that
# only exists in that environment. The .devcontainer/Dockerfile installs exactly the
# versions asserted below, so a rebuilt Codespace should print all PASS.
#
# Exit: 0 = every tool present at the expected version; 1 = something missing or
# version-mismatched (i.e. an audit stage would SKIP or behave differently).
#
# Each tool maps to a scripts/contract-audit.sh stage:
#   forge/cast/anvil -> build/test/coverage/invariant/fork
#   slither          -> Stage 6 (hard gate)
#   solc             -> Stage 0 pin
#   echidna          -> Stage 5   | aderyn -> Stage 7
#   gambit           -> Stage 8   | halmos -> Stage 8b

set -uo pipefail

# ─── Expected pins (keep in sync with .devcontainer/Dockerfile ARGs) ───
EXP_FOUNDRY="1.7.1"
EXP_SLITHER="0.11.5"
EXP_SOLC="0.8.28"
EXP_HALMOS="0.3.3"
EXP_ADERYN="0.6.8"
EXP_ECHIDNA="2.3.2"
EXP_GAMBIT="1.0.6"

FAIL=0
printf '%-10s %-12s %-12s %-8s %s\n' "TOOL" "EXPECTED" "FOUND" "STATUS" "STAGE"
printf '%-10s %-12s %-12s %-8s %s\n' "----" "--------" "-----" "------" "-----"

# ver_of <cmd> <args...> : print first semver-looking token from the tool's version output
ver_of() {
  local cmd="$1"; shift
  command -v "$cmd" >/dev/null 2>&1 || { echo ""; return; }
  "$cmd" "$@" 2>&1 | grep -oiE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

row() { # name expected found stage
  local name="$1" exp="$2" found="$3" stage="$4" status
  if [ -z "$found" ]; then
    status="MISSING"; FAIL=1
  elif [ "$found" = "$exp" ]; then
    status="PASS"
  else
    status="MISMATCH"; FAIL=1
  fi
  printf '%-10s %-12s %-12s %-8s %s\n' "$name" "$exp" "${found:-—}" "$status" "$stage"
}

row forge   "$EXP_FOUNDRY" "$(ver_of forge --version)"   "build/test/cov/inv"
row cast    "$EXP_FOUNDRY" "$(ver_of cast --version)"    "fork/util"
row anvil   "$EXP_FOUNDRY" "$(ver_of anvil --version)"   "fork"
row slither "$EXP_SLITHER" "$(ver_of slither --version)" "6 (hard gate)"
row solc    "$EXP_SOLC"    "$(ver_of solc --version)"    "0 (pin)"
row echidna "$EXP_ECHIDNA" "$(ver_of echidna --version)" "5 fuzzing"
row aderyn  "$EXP_ADERYN"  "$(ver_of aderyn --version)"  "7 static"
# gambit exposes no version flag (only `mutate`/`summary`) — presence-only check;
# the exact version is guaranteed by the Dockerfile pin.
if command -v gambit >/dev/null 2>&1; then
  printf '%-10s %-12s %-12s %-8s %s\n' "gambit" "$EXP_GAMBIT" "present" "PASS" "8 mutation"
else
  printf '%-10s %-12s %-12s %-8s %s\n' "gambit" "$EXP_GAMBIT" "—" "MISSING" "8 mutation"; FAIL=1
fi
row halmos  "$EXP_HALMOS"  "$(ver_of halmos --version)"  "8b symbolic"

echo
if [ "$FAIL" = "0" ]; then
  echo "verify-audit-toolchain: ALL PRESENT ✅ (every audit stage can run)"
  exit 0
else
  echo "verify-audit-toolchain: INCOMPLETE ❌ (MISSING/MISMATCH rows above = stages that SKIP or differ vs a fully-provisioned local)"
  exit 1
fi
