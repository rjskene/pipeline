#!/bin/bash
set -euo pipefail

# Verifies that skills/classify-issue/SKILL.md has step 4a referencing
# .claude/scratch/issue-, placed AFTER step 2 cache check.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if grep -q ".claude/scratch/issue-" "$TARGET"; then
  ok "classify-issue references .claude/scratch/issue-"
else
  nope ".claude/scratch/issue- not found in classify-issue"
fi

if grep -qE "^4a\." "$TARGET"; then
  ok "step 4a header present"
else
  nope "step 4a header missing"
fi

# 4a must appear AFTER step 4 (score) and BEFORE step 5 (Compose).
awk '
  /^4\. \*\*Score/ { score_line=NR }
  /^4a\./         { ah_line=NR }
  /^5\. \*\*Compose/ { compose_line=NR }
  END {
    if (score_line && ah_line && compose_line && score_line < ah_line && ah_line < compose_line) {
      exit 0
    }
    exit 1
  }
' "$TARGET" && ok "4a sits between step 4 (score) and step 5 (compose)" \
  || nope "4a is not positioned between 4 (score) and 5 (compose)"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
