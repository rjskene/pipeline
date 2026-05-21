#!/bin/bash
# Tests that skills/run/SKILL.md step 1 has been rewritten to invoke the
# batched freshness helper (scripts/classification-freshness.sh) instead of
# the per-issue `gh issue view` loop. Companion to the helper's own unit
# tests in tests/test-classification-freshness-batch.sh (#342).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/run/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 (pattern: $2)"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

want_present() {
  local name="$1" pat="$2"
  inc
  if grep -qE -- "$pat" "$SKILL"; then
    pass_msg "$name"
  else
    fail_msg "$name" "$pat"
  fi
}

want_absent() {
  local name="$1" pat="$2"
  inc
  if grep -qE -- "$pat" "$SKILL"; then
    fail_msg "$name (unexpected pattern present)" "$pat"
  else
    pass_msg "$name"
  fi
}

want_present_fixed() {
  local name="$1" pat="$2"
  inc
  if grep -qF -- "$pat" "$SKILL"; then
    pass_msg "$name"
  else
    fail_msg "$name" "$pat"
  fi
}

# 1. The rewritten step references the batched helper.
want_present "1. references classification-freshness.sh" 'classification-freshness\.sh'

# 2. The per-issue `LATEST_CLASS_TS=$(gh issue view ...)` loop must be GONE.
want_absent "2. legacy LATEST_CLASS_TS= per-issue loop absent" 'LATEST_CLASS_TS=\$\(gh issue view'

# 3. Caching-semantics paragraph preserved verbatim (the rule itself, not the transport).
want_present_fixed \
  "3. caching-semantics rule preserved verbatim" \
  "the latest \`## Classification\` comment's \`createdAt > issue.updatedAt\`"

# 4. READY_ISSUES symbol still referenced downstream (contract preserved).
want_present "4. READY_ISSUES symbol preserved" '\bREADY_ISSUES\b'

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
