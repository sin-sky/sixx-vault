#!/usr/bin/env bash
# install-hooks.sh — point git at the tracked .githooks/ dir (ADR-008 mutation-leak guard).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
chmod +x .githooks/* 2>/dev/null || true
git config core.hooksPath .githooks
echo "core.hooksPath -> .githooks  (pre-commit mutation-leak guard active)"
