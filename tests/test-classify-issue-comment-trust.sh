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
CT_TMP=""
STEP2_TMP="$(mktemp)"
trap 'rm -f "$STEP2_TMP" "$GATE_TMP" "$CT_TMP"' EXIT
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

# --- Task 5: opener-association gate (refuse-and-surface, no label) ---

# Slice the step 0a gate block: from "0a." to the next top-level numbered step.
GATE_TMP="$(mktemp)"
awk '/^0a\./ { inblock = 1 } /^1\. / { inblock = 0 } inblock { print }' "$SKILL_FILE" > "$GATE_TMP"

echo "Test 4: opener check uses the is-trusted-author primitive"
inc
if grep -qF "is-trusted-author" "$SKILL_FILE"; then
  pass_msg "is-trusted-author primitive referenced"
else
  fail_msg "missing is-trusted-author reference"
fi

echo "Test 5: opener association resolved via gh api author_association"
inc
if grep -qF "author_association" "$SKILL_FILE" \
   && grep -qF "gh api repos/\$PIPELINE_REPO/issues" "$SKILL_FILE"; then
  pass_msg "association resolved via gh api repos/\$PIPELINE_REPO/issues author_association"
else
  fail_msg "opener association not resolved via gh api .../author_association"
fi

echo "Test 6: is-trusted-author invoked single-arg over the association string"
inc
if grep -qF 'is-trusted-author "$ASSOC"' "$GATE_TMP"; then
  pass_msg "0a block calls is-trusted-author \"\$ASSOC\" (single-arg)"
else
  fail_msg "0a block does not call single-arg is-trusted-author \"\$ASSOC\""
fi

echo "Test 7: broken two-arg / login call shapes are absent"
inc
if grep -qF "is-trusted-author <N>" "$SKILL_FILE" \
   || grep -qF 'is-trusted-author "$OPENER"' "$SKILL_FILE"; then
  fail_msg "broken two-arg/login is-trusted-author shape present"
else
  pass_msg "no broken two-arg/login is-trusted-author shape"
fi

echo "Test 8: refuse-and-surface language present"
inc
if grep -qiE "refuse|human triage" "$SKILL_FILE"; then
  pass_msg "refuse/human-triage language present"
else
  fail_msg "missing refuse-and-surface language"
fi

echo "Test 9: untrusted opener applies no label and posts no classification"
inc
if grep -qi "do NOT apply" "$GATE_TMP" && grep -qi "do NOT post" "$GATE_TMP"; then
  pass_msg "0a block states do-NOT-apply (label) and do-NOT-post (Classification)"
else
  fail_msg "0a block missing do-NOT-apply / do-NOT-post directives"
fi

echo "Test 10: the gate keys off the OPENER"
inc
if grep -qi "opener" "$GATE_TMP"; then
  pass_msg "0a block keys off the opener"
else
  fail_msg "0a block does not mention the opener"
fi

# --- Task 6: `## Comment trust` prose contract section ---

echo "Test 11: SKILL documents a '## Comment trust' section"
inc
if grep -qiE "Comment trust" "$SKILL_FILE"; then
  pass_msg "'Comment trust' section present"
else
  fail_msg "missing '## Comment trust' section"
fi

echo "Test 12: section names the trust tier set OWNER/MEMBER/COLLABORATOR"
inc
if grep -qiE "OWNER.*MEMBER.*COLLABORATOR" "$SKILL_FILE"; then
  pass_msg "trust tier set named"
else
  fail_msg "trust tier set (OWNER/MEMBER/COLLABORATOR) not named"
fi

echo "Test 13: section names the #545 dependency / helper"
inc
if grep -qF "#545" "$SKILL_FILE" || grep -qF "filter-trusted-comments.sh" "$SKILL_FILE"; then
  pass_msg "dependency on #545 / filter-trusted-comments.sh named"
else
  fail_msg "missing #545 / filter-trusted-comments.sh dependency reference"
fi

# --- Issue #1196: the refusal must be idempotent and terminal ---
#
# The step-0a refusal aftermath moves into the shared helper
# scripts/refuse-untrusted-opener.sh (executable coverage lives in
# tests/test-refuse-untrusted-opener.sh). The gate itself is unchanged —
# Tests 4-10 above still hold.

echo "Test 14: step 0a routes the refusal through refuse-untrusted-opener.sh"
inc
if grep -qF "scripts/refuse-untrusted-opener.sh" "$GATE_TMP"; then
  pass_msg "0a block invokes scripts/refuse-untrusted-opener.sh"
else
  fail_msg "0a block does not invoke scripts/refuse-untrusted-opener.sh"
fi

echo "Test 15: no bare 'gh issue comment' remains in the 0a refusal branch"
inc
if grep -qF 'gh issue comment <N>' "$GATE_TMP" \
   || grep -qF 'gh issue comment "$N"' "$GATE_TMP"; then
  fail_msg "bare 'gh issue comment' still present in the 0a refusal branch (non-idempotent)"
else
  pass_msg "refusal comment no longer posted by a bare unconditional gh issue comment"
fi

echo "Test 16: 0a prose states the refusal is idempotent and applies the human label"
inc
if grep -qiE "idempotent|no duplicate|duplicate|already (present|posted)" "$GATE_TMP" \
   && grep -qE 'PIPELINE_LABELS_HUMAN|`human`' "$GATE_TMP"; then
  pass_msg "0a prose names idempotency AND the PIPELINE_LABELS_HUMAN/\`human\` label"
else
  fail_msg "0a prose missing idempotency and/or PIPELINE_LABELS_HUMAN/\`human\` label outcome"
fi

echo "Test 17: '## Comment trust' section documents the durable human-label outcome"
inc
CT_TMP="$(mktemp)"
awk '/^## Comment trust/ { inblock = 1; next } /^## / { inblock = 0 } inblock { print }' "$SKILL_FILE" > "$CT_TMP"
if grep -qE 'PIPELINE_LABELS_HUMAN|`human`' "$CT_TMP" \
   && grep -qiE "idempotent|no duplicate|duplicate|already (present|posted)" "$CT_TMP"; then
  pass_msg "'Comment trust' section states the refusal is idempotent and labels the issue"
else
  fail_msg "'Comment trust' section missing idempotency / human-label outcome"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
