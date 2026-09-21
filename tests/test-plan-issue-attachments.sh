#!/bin/bash
set -euo pipefail

# Verifies that skills/plan-issue/SKILL.md has step 3b referencing
# .claude/scratch/issue- AND invoking the sanctioned
# filter-trusted-comments.sh fetch-attachments fence (#1340 — routes around
# enforce-comment-trust.py's direct fetch-issue-attachments.sh denial),
# placed between step 3a (PATH determination) and step 4 (Explore the
# codebase).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../skills/plan-issue/SKILL.md"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

grep -q ".claude/scratch/issue-" "$TARGET" \
  && ok ".claude/scratch/issue- present in plan-issue" \
  || nope ".claude/scratch/issue- missing"

grep -qF 'scripts/filter-trusted-comments.sh" fetch-attachments <N>' "$TARGET" \
  && ok "plan-issue invokes the sanctioned fetch-attachments fence" \
  || nope "plan-issue does not invoke filter-trusted-comments.sh fetch-attachments"

if grep -qF 'scripts/fetch-issue-attachments.sh" <N>' "$TARGET"; then
  nope "plan-issue still directly invokes fetch-issue-attachments.sh (bypasses the trust-filter hook)"
else
  ok "plan-issue no longer directly invokes fetch-issue-attachments.sh"
fi

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
