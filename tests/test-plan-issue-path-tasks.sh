#!/bin/bash
set -euo pipefail

# Tests for the PATH-aware Task 0 / Task N wording in the plan-issue skill
# (.claude-pipeline/skills/plan-issue/SKILL.md.template).
#
# plan-issue now emits a `**Tasks (ordered):**` section whose Task 0 differs
# per PATH (A/B/C) and whose final Task N is a self-verification checkpoint.
# This test renders the template with envsubst and greps for the expected
# directives inside each path-branch block.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../skills/plan-issue/SKILL.md.template"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: plan-issue template not found at $TEMPLATE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

RENDERED="$WORKDIR/SKILL.md"
PIPELINE_REPO="fake/repo" \
  PIPELINE_CONTEXT_FILES="CLAUDE.md" \
  PIPELINE_TEST_CMD="bash verify.sh" \
  envsubst '$PIPELINE_REPO $PIPELINE_CONTEXT_FILES $PIPELINE_TEST_CMD' \
    < "$TEMPLATE" > "$RENDERED"

# Extract the content of a "#### Task 0 — PATH X" section up to the next
# "#### " heading (or end of file). Returns the block text on stdout.
extract_section() {
  local letter="$1"
  awk -v start="^#### Task 0 — PATH ${letter}" '
    $0 ~ start              { inblock = 1; print; next }
    inblock && /^#### /     { inblock = 0 }
    inblock                 { print }
  ' "$RENDERED"
}

BLOCK_A=$(extract_section "A")
BLOCK_B=$(extract_section "B")
BLOCK_C=$(extract_section "C")

# --- Test 1: PATH detection step exists ---
echo "Test 1: plan-issue has a PATH-detection step"
inc
if grep -qE "PATH_LETTER=A" "$RENDERED" \
   && grep -qE "PATH_LETTER=C" "$RENDERED" \
   && grep -qE "PATH_LETTER=B" "$RENDERED" \
   && grep -qE "docs-only" "$RENDERED" \
   && grep -qE "multi-task" "$RENDERED"; then
  pass_msg "PATH detection inspects docs-only/multi-task labels"
else
  fail_msg "rendered skill missing PATH_LETTER detection against labels"
fi

# --- Test 2: PATH A block exists and omits TDD ---
echo "Test 2: PATH A Task 0 omits test-driven-development"
inc
if [ -z "$BLOCK_A" ]; then
  fail_msg "no '#### Task 0 — PATH A' section found"
elif echo "$BLOCK_A" | grep -qi "test-driven-development"; then
  fail_msg "PATH A Task 0 references test-driven-development — should be docs-only, no TDD cycle"
else
  pass_msg "PATH A Task 0 has no TDD directive"
fi

# --- Test 3: PATH B block requires superpowers:test-driven-development ---
echo "Test 3: PATH B Task 0 invokes superpowers:test-driven-development"
inc
if [ -z "$BLOCK_B" ]; then
  fail_msg "no '#### Task 0 — PATH B' section found"
elif echo "$BLOCK_B" | grep -q "superpowers:test-driven-development"; then
  pass_msg "PATH B Task 0 requires superpowers:test-driven-development"
else
  fail_msg "PATH B Task 0 does not invoke superpowers:test-driven-development"
fi

# --- Test 4: PATH C block requires tdd-implementer dispatch with target sentinel ---
echo "Test 4: PATH C Task 0 dispatches tdd-implementer with target=<dir>"
inc
if [ -z "$BLOCK_C" ]; then
  fail_msg "no '#### Task 0 — PATH C' section found"
elif echo "$BLOCK_C" | grep -q "subagent_type='tdd-implementer'" \
   && echo "$BLOCK_C" | grep -qE "target=<"; then
  pass_msg "PATH C Task 0 dispatches tdd-implementer with target=<dir> sentinel"
else
  fail_msg "PATH C Task 0 missing tdd-implementer dispatch or target=<...> sentinel"
fi

# --- Test 5: final Task N directive references requesting-code-review ---
echo "Test 5: final Task N calls superpowers:requesting-code-review"
inc
if grep -q "superpowers:requesting-code-review" "$RENDERED"; then
  pass_msg "requesting-code-review is referenced as final Task N"
else
  fail_msg "no superpowers:requesting-code-review directive in rendered template"
fi

# --- Test 6: canonical plan format now includes **Tasks (ordered):** ---
echo "Test 6: canonical plan format contains Tasks (ordered): section"
inc
if grep -qE "\*\*Tasks \(ordered\):\*\*" "$RENDERED"; then
  pass_msg "Tasks (ordered): section present in canonical plan format"
else
  fail_msg "canonical plan format missing **Tasks (ordered):** section"
fi

# --- Test 7: PATH B block describes red->green cycle ---
echo "Test 7: PATH B Task 0 mentions red->green commit cycle"
inc
if echo "$BLOCK_B" | grep -qE "red.+green|failing test|watch it fail"; then
  pass_msg "PATH B Task 0 mentions red-green cycle"
else
  fail_msg "PATH B Task 0 missing red-green cycle language"
fi

# --- Test 8: PATH C Task 0 notes orchestrator cannot Write/Edit impl files ---
echo "Test 8: PATH C Task 0 notes orchestrator Write/Edit restriction"
inc
if echo "$BLOCK_C" | grep -qE "enforce-path-c-delegation|orchestrator .* (NOT|must not) .*(Write|Edit)"; then
  pass_msg "PATH C Task 0 notes the delegation hook / orchestrator edit restriction"
else
  fail_msg "PATH C Task 0 missing orchestrator-edit restriction notice"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
