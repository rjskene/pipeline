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
# block boundary. Returns the block text on stdout.
#
# The boundary is the next "#### " path heading, ANY "## " section heading, or
# the next numbered step line (e.g. `6. **Write the plan ...`). A "#### "-only
# terminator is NOT sufficient: PATH D is the LAST "#### " heading in the file,
# so BLOCK_D would run to EOF and swallow ## Revision handling / ## Comment
# trust / ## Constraints — letting an unrelated match below the block satisfy a
# PATH D assertion (notably Test 12's do-NOT clause).
extract_section() {
  local letter="$1"
  awk -v start="^#### Task 0 — PATH ${letter}" '
    $0 ~ start                            { inblock = 1; print; next }
    inblock && /^(#### |## |[0-9]+\. )/   { inblock = 0 }
    inblock                               { print }
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

# --- Test 3: PATH B block carries the INLINE TDD discipline (#1419) -------
# #1419 removed the superpowers dependency: PATH B Task 0 no longer invokes a
# skill, it names the discipline and points at the agent that already carries
# it verbatim. The negative half is load-bearing — an assertion that only
# looked for "test-driven-development" would pass on the old
# `superpowers:test-driven-development` invocation too.
echo "Test 3: PATH B Task 0 names the inline test-driven-development discipline"
inc
if [ -z "$BLOCK_B" ]; then
  fail_msg "no '#### Task 0 — PATH B' section found"
elif echo "$BLOCK_B" | grep -qF "test-driven-development discipline" \
   && echo "$BLOCK_B" | grep -qF "agents/tdd-implementer.md" \
   && ! echo "$BLOCK_B" | grep -qF "superpowers:"; then
  pass_msg "PATH B Task 0 names the inline TDD discipline and cites agents/tdd-implementer.md"
else
  fail_msg "PATH B Task 0 must name 'test-driven-development discipline', cite 'agents/tdd-implementer.md', and carry NO 'superpowers:' invocation"
fi

# --- Test 4: PATH C block requires tdd-implementer dispatch with target sentinel ---
echo "Test 4: PATH C Task 0 dispatches tdd-implementer with target=<dir>"
inc
if [ -z "$BLOCK_C" ]; then
  fail_msg "no '#### Task 0 — PATH C' section found"
elif echo "$BLOCK_C" | grep -q "subagent_type='pipeline:tdd-implementer'" \
   && echo "$BLOCK_C" | grep -qE "target=<"; then
  pass_msg "PATH C Task 0 dispatches tdd-implementer with target=<dir> sentinel"
else
  fail_msg "PATH C Task 0 missing tdd-implementer dispatch or target=<...> sentinel"
fi

# --- Test 5: final Task N runs the pre-PR self-check INLINE (#1419) -------
# The closing task used to dispatch `superpowers:requesting-code-review`; it
# now runs the same checklist inline. Scoped to the `- Task N:` bullet so a
# match elsewhere in the skill cannot satisfy it, and paired with the negative
# so the old invocation (whose #1412 fallback clause already said "run the
# self-check inline") cannot pass this assertion.
echo "Test 5: final Task N runs the pre-PR self-check inline"
inc
TASKN=$(grep -F -- '- Task N:' "$RENDERED" | head -1 || true)
if [ -z "$TASKN" ]; then
  fail_msg "no '- Task N:' bullet found in the rendered skill"
elif printf '%s' "$TASKN" | grep -qF "self-check" \
   && printf '%s' "$TASKN" | grep -qF "inline" \
   && ! printf '%s' "$TASKN" | grep -qF "superpowers:"; then
  pass_msg "Task N runs the self-check inline, with no superpowers: invocation"
else
  fail_msg "Task N bullet must name an inline 'self-check' and carry NO 'superpowers:' invocation"
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

# --- Test 12: PATH D block forbids dispatching a review subagent (#1419) --
# The prohibition survives the dependency removal — it was never about the
# skill NAME, it is about the PATH D envelope forbidding any subagent. The
# clause is therefore reworded to the capability, and the rationale
# ("PATH D envelope forbids") must stay attached to it.
echo "Test 12: PATH D Task N substitute forbids dispatching a review subagent"
inc
if [ -z "$BLOCK_D" ]; then
  fail_msg "no '#### Task 0 — PATH D' section found"
elif echo "$BLOCK_D" | grep -qiF "do NOT dispatch a review subagent" \
   && echo "$BLOCK_D" | grep -qi "PATH D envelope forbids" \
   && ! echo "$BLOCK_D" | grep -qF "superpowers:"; then
  pass_msg "PATH D block forbids dispatching a review subagent, with the envelope rationale"
else
  fail_msg "PATH D block must carry 'do NOT dispatch a review subagent' + the 'PATH D envelope forbids' rationale, and NO 'superpowers:' invocation"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
