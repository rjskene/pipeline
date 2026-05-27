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

# --- Task 2: plan-revision detection keys off trusted feedback only ---

echo "Test 3: SKILL names a trusted feedback/comment/author qualifier"
inc
if grep -qiE "trusted (feedback|comment|author)" "$SKILL_FILE"; then
  pass_msg "trusted feedback/comment/author qualifier present"
else
  fail_msg "no 'trusted feedback/comment/author' qualifier found"
fi

echo "Test 4: step 2 ties plan-revision to a trusted-only qualifier"
inc
STEP2_TMP="$(mktemp)"
trap 'rm -f "$STEP2_TMP"' EXIT
awk '/^2\. / { inblock = 1 } /^3\. / { inblock = 0 } inblock { print }' "$SKILL_FILE" > "$STEP2_TMP"
if grep -qiF "Changes from previous plan" "$STEP2_TMP" && grep -qi "trusted" "$STEP2_TMP"; then
  pass_msg "step 2 mentions 'Changes from previous plan' AND a trusted qualifier"
else
  fail_msg "step 2 missing 'Changes from previous plan' + trusted qualifier"
fi

echo "Test 5: an untrusted/outsider comment cannot force a revision"
inc
if grep -qiE "outsider|untrusted" "$SKILL_FILE"; then
  pass_msg "negative-intent (outsider/untrusted) language present"
else
  fail_msg "no 'outsider'/'untrusted' negative-intent language"
fi

# --- Task 3: opener-association gate + trusted Classification fallback ---

# Slice the step 0a gate block: from "0a." to the next top-level numbered
# step "1. ".
GATE_TMP="$(mktemp)"
trap 'rm -f "$STEP2_TMP" "$GATE_TMP" "$STEP3A_TMP"' EXIT
awk '/^0a\./ { inblock = 1 } /^1\. / { inblock = 0 } inblock { print }' "$SKILL_FILE" > "$GATE_TMP"

# Slice step 3a: from "3a." to "3b.".
STEP3A_TMP="$(mktemp)"
awk '/^3a\./ { inblock = 1 } /^3b\./ { inblock = 0 } inblock { print }' "$SKILL_FILE" > "$STEP3A_TMP"

echo "Test 6: opener check uses the is-trusted-author primitive"
inc
if grep -qF "is-trusted-author" "$SKILL_FILE"; then
  pass_msg "is-trusted-author primitive referenced"
else
  fail_msg "missing is-trusted-author reference"
fi

echo "Test 7: opener association resolved via gh api author_association"
inc
if grep -qF "author_association" "$SKILL_FILE" \
   && grep -qF "gh api repos/\$PIPELINE_REPO/issues" "$SKILL_FILE"; then
  pass_msg "association resolved via gh api repos/\$PIPELINE_REPO/issues author_association"
else
  fail_msg "opener association not resolved via gh api .../author_association"
fi

echo "Test 8: is-trusted-author invoked single-arg over the association string"
inc
if grep -qF 'is-trusted-author "$ASSOC"' "$GATE_TMP"; then
  pass_msg "0a block calls is-trusted-author \"\$ASSOC\" (single-arg)"
else
  fail_msg "0a block does not call single-arg is-trusted-author \"\$ASSOC\""
fi

echo "Test 9: broken two-arg / login call shapes are absent"
inc
if grep -qF "is-trusted-author <N>" "$SKILL_FILE" \
   || grep -qF 'is-trusted-author "$OPENER"' "$SKILL_FILE"; then
  fail_msg "broken two-arg/login is-trusted-author shape present"
else
  pass_msg "no broken two-arg/login is-trusted-author shape"
fi

echo "Test 10: refuse-and-surface language present"
inc
if grep -qiE "refuse|human triage|do NOT post" "$SKILL_FILE"; then
  pass_msg "refuse/human-triage/do-NOT-post language present"
else
  fail_msg "missing refuse-and-surface language"
fi

echo "Test 11: the gate is on the OPENER and surfaces for human triage"
inc
if grep -qi "opener" "$GATE_TMP" && grep -qi "human triage" "$GATE_TMP"; then
  pass_msg "0a block names the opener and human triage"
else
  fail_msg "0a block missing opener / human triage language"
fi

echo "Test 12: step 3a Classification fallback reads from the trusted set"
inc
if grep -qF "filter-trusted-comments.sh" "$STEP3A_TMP" \
   || grep -qF "\$TRUSTED" "$STEP3A_TMP"; then
  pass_msg "step 3a fallback reads trusted set (\$TRUSTED or helper)"
else
  fail_msg "step 3a fallback still uses a raw --json comments fetch"
fi

# --- Task 6: `## Comment trust` prose contract section ---

echo "Test 13: SKILL documents a '## Comment trust' section"
inc
if grep -qiE "Comment trust" "$SKILL_FILE"; then
  pass_msg "'Comment trust' section present"
else
  fail_msg "missing '## Comment trust' section"
fi

echo "Test 14: section names the trust tier set OWNER/MEMBER/COLLABORATOR"
inc
if grep -qiE "OWNER.*MEMBER.*COLLABORATOR" "$SKILL_FILE"; then
  pass_msg "trust tier set named"
else
  fail_msg "trust tier set (OWNER/MEMBER/COLLABORATOR) not named"
fi

echo "Test 15: section names the #545 dependency / helper"
inc
if grep -qF "#545" "$SKILL_FILE" || grep -qF "filter-trusted-comments.sh" "$SKILL_FILE"; then
  pass_msg "dependency on #545 / filter-trusted-comments.sh named"
else
  fail_msg "missing #545 / filter-trusted-comments.sh dependency reference"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
