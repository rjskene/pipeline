#!/bin/bash
set -euo pipefail

# Verifies that skills/plan-issue/SKILL.md has step 3b referencing
# .claude/scratch/issue- AND fetch-issue-attachments.sh, placed between
# step 3a (PATH determination) and step 4 (Explore the codebase).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../skills/plan-issue/SKILL.md"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

grep -q ".claude/scratch/issue-" "$TARGET" \
  && ok ".claude/scratch/issue- present in plan-issue" \
  || nope ".claude/scratch/issue- missing"

grep -q "fetch-issue-attachments.sh" "$TARGET" \
  && ok "fetch-issue-attachments.sh referenced in plan-issue" \
  || nope "fetch-issue-attachments.sh not referenced"

grep -qE "^3b\." "$TARGET" \
  && ok "step 3b header present" \
  || nope "step 3b header missing"

# Ordering: 3a must precede 3b which must precede 4.
awk '
  /^3a\./ { a=NR }
  /^3b\./ { b=NR }
  /^4\. \*\*Explore/ { c=NR }
  END {
    if (a && b && c && a < b && b < c) exit 0
    exit 1
  }
' "$TARGET" \
  && ok "3b sits between 3a (PATH) and 4 (Explore)" \
  || nope "3b is not positioned between 3a and 4"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
