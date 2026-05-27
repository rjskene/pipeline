#!/bin/bash
set -euo pipefail

# Tests for issue #546: plan-issue must gate plan generation by author
# association — all comment/body reads route through the #545 trust-filter
# helper (scripts/filter-trusted-comments.sh), plan-revision detection keys
# off trusted feedback only, and an opener-association gate refuses-and-
# surfaces an issue whose opener lacks write access.
#
# These are grep/awk prose-contract assertions over the canonical SKILL.md,
# same idiom as tests/test-plan-issue-post-gate.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../skills/plan-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: plan-issue SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi

# --- Task 1: helper-routed comment/body fetch ---

echo "Test 1: trust-filter helper referenced"
inc
if grep -qF "scripts/filter-trusted-comments.sh" "$SKILL_FILE"; then
  pass_msg "scripts/filter-trusted-comments.sh is referenced"
else
  fail_msg "missing scripts/filter-trusted-comments.sh reference"
fi

echo "Test 2: raw un-filtered comments fetch removed from the fetch step"
inc
if grep -qF "gh issue view <N> --repo \$PIPELINE_REPO --json comments --jq '.comments[]" "$SKILL_FILE"; then
  fail_msg "raw 'gh issue view ... --json comments --jq .comments[]' fetch still present (must route through helper)"
else
  pass_msg "raw un-filtered comments fetch removed"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
