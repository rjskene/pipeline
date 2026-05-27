#!/bin/bash
set -euo pipefail

# Tests for issue #546: classify-issue must gate classification by author
# association. All body/comment reads route through the #545 trust-filter
# helper (scripts/filter-trusted-comments.sh); the cache-check parses the
# trusted set; and an opener-association gate refuses-and-surfaces an issue
# whose opener lacks write access (no path label, no ## Classification
# comment).
#
# Grep/awk prose-contract assertions over the canonical SKILL.md, same idiom
# as tests/test-classify-applies-label.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: classify-issue SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi

# Slice step 2 (cache check): from "2. " to "3. ".
GATE_TMP=""
STEP2_TMP="$(mktemp)"
trap 'rm -f "$STEP2_TMP" "$GATE_TMP"' EXIT
awk '/^2\. / { inblock = 1 } /^3\. / { inblock = 0 } inblock { print }' "$SKILL_FILE" > "$STEP2_TMP"

# --- Task 4: helper-routed body/comment fetch + cache-check ---

echo "Test 1: trust-filter helper referenced"
inc
if grep -qF "scripts/filter-trusted-comments.sh" "$SKILL_FILE"; then
  pass_msg "scripts/filter-trusted-comments.sh is referenced"
else
  fail_msg "missing scripts/filter-trusted-comments.sh reference"
fi

echo "Test 2: raw un-filtered comments fetch removed from step 1"
inc
if grep -qF "gh issue view <N> --repo \$PIPELINE_REPO --json comments --jq '.comments[]" "$SKILL_FILE"; then
  fail_msg "raw 'gh issue view ... --json comments --jq .comments[]' fetch still present"
else
  pass_msg "raw un-filtered comments fetch removed"
fi

echo "Test 3: cache-check still parses ## Classification on the trusted set"
inc
if grep -qF "## Classification" "$SKILL_FILE" \
   && { grep -qF "filter-trusted-comments.sh" "$STEP2_TMP" || grep -qF "\$TRUSTED" "$STEP2_TMP"; }; then
  pass_msg "step 2 parses ## Classification and operates on trusted content"
else
  fail_msg "step 2 missing ## Classification trust-set wiring"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
