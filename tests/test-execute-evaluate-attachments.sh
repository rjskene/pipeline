#!/bin/bash
set -euo pipefail

# Verifies that execute-issue-plan and evaluate-issue-pr SKILL.md files
# both reference .claude/scratch/issue- as a Read target.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXEC="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"
EVAL="$SCRIPT_DIR/../skills/evaluate-issue-pr/SKILL.md"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

grep -q ".claude/scratch/issue-" "$EXEC" \
  && ok "execute-issue-plan references .claude/scratch/issue-" \
  || nope "execute-issue-plan missing scratch reference"

grep -q ".claude/scratch/issue-" "$EVAL" \
  && ok "evaluate-issue-pr references .claude/scratch/issue-" \
  || nope "evaluate-issue-pr missing scratch reference"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
