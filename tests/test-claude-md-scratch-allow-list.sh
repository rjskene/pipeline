#!/bin/bash
set -euo pipefail

# Ensures CLAUDE.md lists `.claude/scratch/` under the Runtime allow-list
# bullet section.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../CLAUDE.md"

# Look for a bullet under the Runtime allow-list block that mentions
# `.claude/scratch/` between the "Runtime allow-list" header and the
# next blank-paragraph boundary.
if awk '/Runtime allow-list/{flag=1} flag && /\.claude\/scratch\//{found=1; exit} /^Everything else/{flag=0} END{exit !found}' "$TARGET"; then
  echo "  PASS: .claude/scratch/ bullet present in Runtime allow-list"
  exit 0
else
  echo "  FAIL: CLAUDE.md Runtime allow-list does not list .claude/scratch/"
  exit 1
fi
