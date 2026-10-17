#!/bin/bash
set -euo pipefail

# Verifies that skills/fullsend/SKILL.md step 1 invokes the sanctioned
# filter-trusted-comments.sh fetch-attachments <N> fence (#1340 — routes
# around enforce-comment-trust.py's direct fetch-issue-attachments.sh
# denial) for each slate issue before the per-issue plan-issue dispatch.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../skills/fullsend/SKILL.md"
# Step 1a calls the wave helper, which owns the per-issue sanctioned loop.
HELPER="$SCRIPT_DIR/../scripts/fullsend-fetch-attachments.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if grep -qF 'scripts/fullsend-fetch-attachments.sh"' "$TARGET"; then
  ok "fullsend SKILL.md invokes the fullsend-fetch-attachments.sh helper"
else
  nope "fullsend SKILL.md does not invoke the fullsend-fetch-attachments.sh helper"
fi
if grep -qF 'filter-trusted-comments.sh" fetch-attachments "$N"' "$HELPER"; then
  ok "the helper invokes the sanctioned filter-trusted-comments.sh fetch-attachments call"
else
  nope "the helper does not invoke filter-trusted-comments.sh fetch-attachments"
fi

if grep -qF 'fetch-issue-attachments.sh" "$N"' "$TARGET" "$HELPER"; then
  nope "fullsend SKILL.md or its helper directly invokes fetch-issue-attachments.sh (bypasses the trust-filter hook)"
else
  ok "neither fullsend SKILL.md nor its helper directly invokes fetch-issue-attachments.sh"
fi

# Sanity: the invocation should land in step 1 (Plan), BEFORE the plan-issue
# dispatch sentence. Use awk to assert ordering.
if awk '/^1\.\s*\*\*Plan\*\*/{flag=1} flag && /fetch-attachments/{found_before_plan_issue=1} flag && /classify-issue/{if(found_before_plan_issue){pass=1}; exit} END{exit !pass}' "$TARGET"; then
  ok "fetch-attachments invocation precedes classify-issue dispatch in step 1"
else
  nope "fetch-attachments invocation is not in step 1 before classify-issue dispatch"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
