#!/bin/bash
set -euo pipefail

# Ensures the repo's own .gitignore ignores /.claude/scratch/, so
# attachment artifacts ingested by fetch-issue-attachments.sh are not
# accidentally committed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GITIGNORE="$SCRIPT_DIR/../.gitignore"

if grep -qE '^/?\.claude/scratch/?' "$GITIGNORE"; then
  echo "PASS: /.claude/scratch/ is gitignored"
  exit 0
else
  echo "FAIL: .gitignore is missing the /.claude/scratch/ line"
  exit 1
fi
