#!/usr/bin/env bash
# make-handoff.sh — build the standalone reviewer handoff bundle (ADR-006).
#
# Produces a self-contained, offline-buildable zip a third-party auditor can use as-is:
#   in-scope src/ + test/ + pinned lib/ (OZ v5.6.1, forge-std v1.16.1) + audit docs + config.
# Secrets (.env / keys / RPC) and generated/provenance dirs are NEVER included, and a
# secret-scan gate fails the build if anything key-shaped slips in.
#
# Usage:   ./scripts/make-handoff.sh
# Output:  handoff/sixx-vault-audit-handoff-<shorthash>.zip   (gitignored)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HASH="$(git rev-parse --short HEAD)"
NAME="sixx-vault-audit-handoff-${HASH}"
STAGE="handoff/${NAME}"
ZIP="handoff/${NAME}.zip"

echo "==> Building handoff bundle for ${HASH}"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"

# ── Include: source, tests, pinned libs (no .git), config, scripts, audit docs ──
copy() { # src dst
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' --exclude='.git/**' "$1" "$2"
  else
    cp -R "$1" "$2"; find "$2" -name '.git' -prune -exec rm -rf {} + 2>/dev/null || true
  fi
}
copy "src"        "$STAGE/"
copy "test"       "$STAGE/"
copy "script"     "$STAGE/"        # deploy/wiring scripts (public addrs only; DeployWiring.t.sol needs them)
copy "lib"        "$STAGE/"        # OZ + forge-std, pinned; .git stripped
copy "audit"      "$STAGE/"
copy "docs"       "$STAGE/"        # ADR-007 (architecture/{decisions,designs}), mainnet-gate + runbooks (operations)
mkdir -p "$STAGE/scripts"
cp scripts/contract-audit.sh scripts/mutation-test.sh scripts/make-handoff.sh scripts/verify-audit-toolchain.sh "$STAGE/scripts/"
cp foundry.toml remappings.txt .gitmodules echidna.yaml "$STAGE/"
cp AUDIT_PACKAGE.md PRE_AUDIT_HARDENING.md CLAUDE.md "$STAGE/" 2>/dev/null || true
cp SETUP.md "$STAGE/" 2>/dev/null || true
cp slither-3d55dc5.json slither-ethena.json slither-pendle.json "$STAGE/" 2>/dev/null || true
cp .env.example "$STAGE/" 2>/dev/null || true   # template only (no values)
# Surface the two entry docs at the bundle root for visibility.
cp audit/README_FOR_REVIEWER.md "$STAGE/README_FOR_REVIEWER.md"
cp audit/SCOPE.md               "$STAGE/SCOPE.md"

# ── Hard-exclude anything sensitive/generated that might have been copied ──
find "$STAGE" \( \
     -name '.env' -o -name '*.env' -o -name '.env.local' \
  -o -path '*/broadcast/*' -o -name 'broadcast' -type d \
  -o -path '*/.venv-audit/*' -o -name '.venv-audit' -type d \
  -o -path '*/reports/*' -o -path '*/out/*' -o -path '*/cache/*' \
  -o -path '*/gambit_out/*' -o -path '*/echidna-corpus/*' \
  \) -prune -exec rm -rf {} + 2>/dev/null || true
# Keep the safe template even though the *.env glob would match it.
[ -f "audit/../.env.example" ] && cp .env.example "$STAGE/.env.example"

# ── Secret-scan gate (fail closed) ──
echo "==> Secret scan…"
LEAK=0
# 1) any real .env (not the empty template)
if find "$STAGE" -name '.env' -o -name '.env.local' | grep -q .; then
  echo "  ✗ a real .env file is present"; LEAK=1
fi
# 2) 32-byte hex private-key literal
if grep -rIlE '\b(0x)?[0-9a-fA-F]{64}\b' "$STAGE" \
     --exclude-dir=lib --exclude='*.json' 2>/dev/null | grep -q .; then
  echo "  ✗ a 64-hex (private-key-shaped) literal found outside lib/json";
  grep -rlE '\b(0x)?[0-9a-fA-F]{64}\b' "$STAGE" --exclude-dir=lib --exclude='*.json' | head; LEAK=1
fi
# 3) non-empty secret assignments
if grep -rIE '(PRIVATE_KEY|MNEMONIC|_API_KEY|RPC_URL)[[:space:]]*=[[:space:]]*[^[:space:]]' "$STAGE" \
     --include='*.env*' 2>/dev/null | grep -vE '=\s*$' | grep -q .; then
  echo "  ✗ a populated secret assignment found in an env file"; LEAK=1
fi
if [ "$LEAK" != "0" ]; then
  echo "==> ABORT: potential secret in bundle — not zipping."; exit 1
fi
echo "  ✓ no secrets detected"

# ── Zip ──
( cd handoff && zip -q -r "${NAME}.zip" "${NAME}" )
SIZE="$(du -h "$ZIP" | cut -f1)"
FILES="$(find "$STAGE" -type f | wc -l | tr -d ' ')"
echo "==> Built: $ZIP  (${SIZE}, ${FILES} files)"
echo "    frozen commit: ${HASH}"
