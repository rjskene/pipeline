#!/bin/bash
set -euo pipefail

# Verifies that skills/fullsend/SKILL.md step 1 invokes
# fetch-issue-attachments.sh for each slate issue before the per-issue
# plan-issue dispatch.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../skills/fullsend/SKILL.md"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if grep -q "fetch-issue-attachments.sh" "$TARGET"; then
  ok "fullsend SKILL.md references fetch-issue-attachments.sh"
else
  nope "fullsend SKILL.md does not invoke fetch-issue-attachments.sh"
fi

# Sanity: the invocation should land in step 1 (Plan), BEFORE the plan-issue
# dispatch sentence. Use awk to assert ordering.
if awk '/^1\.\s*\*\*Plan\*\*/{flag=1} flag && /fetch-issue-attachments.sh/{found_before_plan_issue=1} flag && /classify-issue/{if(found_before_plan_issue){pass=1}; exit} END{exit !pass}' "$TARGET"; then
  ok "fetch invocation precedes classify-issue dispatch in step 1"
else
  nope "fetch invocation is not in step 1 before classify-issue dispatch"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
