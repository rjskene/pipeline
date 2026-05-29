#!/usr/bin/env bash
set -euo pipefail

# dogfood-mode.sh — Swap to the dogfood (local file://) marketplace install.
#
# Thin wrapper around setup-dogfood-local.sh. After this runs, the operator
# must finish the install interactively with:
#     /plugin install pipeline@claude-pipeline-local

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "$REPO_ROOT/scripts/setup-dogfood-local.sh" "$@"
echo "current install: local (claude-pipeline-local @ $REPO_ROOT)"
