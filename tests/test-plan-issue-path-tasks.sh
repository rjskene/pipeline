#!/bin/bash
set -euo pipefail

# Tests for the PATH-aware Task 0 / Task N wording in the plan-issue skill
# (skills/plan-issue/SKILL.md at plugin root).
#
# plan-issue emits a `**Tasks (ordered):**` section whose Task 0 differs
# per PATH (A/B/C) and whose final Task N is a self-verification checkpoint.
# This test greps the canonical SKILL.md (no rendering — `$PIPELINE_*` refs
# are now runtime shell variables sourced from pipeline.config) for the
# expected directives inside each path-branch block.

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

RENDERED="$SKILL_FILE"

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
BLOCK_D=$(extract_section "D")

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

# --- Test 9: PATH D block emits the single-instance inline Task 0 ---
echo "Test 9: PATH D Task 0 declares 'you ARE tdd-implementer (single-instance inline)'"
inc
if [ -z "$BLOCK_D" ]; then
  fail_msg "no '#### Task 0 — PATH D' section found"
elif echo "$BLOCK_D" | grep -qF "Task 0: you ARE tdd-implementer (single-instance inline)"; then
  pass_msg "PATH D Task 0 contains the single-instance inline directive"
else
  fail_msg "PATH D Task 0 missing the literal 'Task 0: you ARE tdd-implementer (single-instance inline)' string"
fi

# --- Test 10: PATH D block does NOT dispatch a subagent ---
echo "Test 10: PATH D Task 0 does NOT dispatch Agent(subagent_type=..."
inc
if [ -z "$BLOCK_D" ]; then
  fail_msg "no '#### Task 0 — PATH D' section found"
elif echo "$BLOCK_D" | grep -qF "dispatch Agent(subagent_type="; then
  fail_msg "PATH D Task 0 should be inline — must not contain 'dispatch Agent(subagent_type=' (PATH C wording)"
else
  pass_msg "PATH D Task 0 omits subagent dispatch — runs inline"
fi

# --- Test 11: PATH_LETTER detection branch for quick-fix exists ---
echo "Test 11: PATH_LETTER=D branch is reachable from quick-fix label"
inc
if grep -qE "PATH_LETTER=D" "$RENDERED" \
   && grep -qE "quick-fix" "$RENDERED" \
   && grep -qE 'A\|B\|C\|D' "$RENDERED"; then
  pass_msg "PATH D detected from quick-fix label; cached-comment fallback widened to A|B|C|D"
else
  fail_msg "rendered skill missing PATH_LETTER=D branch / quick-fix label / A|B|C|D fallback"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
