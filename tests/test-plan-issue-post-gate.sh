#!/bin/bash
set -euo pipefail

# Tests for issue #44: plan-issue skill must post via the atomic helper
# (scripts/post-plan.sh) and must NOT terminate with the plan body as final
# agent text. This file greps skills/plan-issue/SKILL.md for the expected
# guardrail string, draft-file path pattern, helper invocation, and the
# absence of the old `gh issue comment --body "<plan markdown>"` call site.

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

echo "Test 1: guardrail string present"
inc
if grep -qF "DO NOT return the plan as your final message" "$SKILL_FILE"; then
  pass_msg "guardrail string is present"
else
  fail_msg "missing guardrail: 'DO NOT return the plan as your final message'"
fi

echo "Test 2: draft-file path pattern referenced"
inc
if grep -qF ".claude/logs/plan-drafts/" "$SKILL_FILE"; then
  pass_msg "draft-file path .claude/logs/plan-drafts/ referenced"
else
  fail_msg "missing draft-file path .claude/logs/plan-drafts/"
fi

echo "Test 3: atomic helper scripts/post-plan.sh referenced"
inc
if grep -qF "scripts/post-plan.sh" "$SKILL_FILE"; then
  pass_msg "scripts/post-plan.sh helper is referenced"
else
  fail_msg "missing scripts/post-plan.sh reference"
fi

echo "Test 4: old terminal-return paragraph removed"
inc
if grep -qF '**Important:** "Return the plan content directly" means return it to THIS agent' "$SKILL_FILE"; then
  fail_msg "old terminal-return paragraph still present"
else
  pass_msg "old terminal-return paragraph removed"
fi

echo "Test 5: old direct gh issue comment --body \"<plan markdown>\" call removed"
inc
if grep -qF 'gh issue comment <N> --repo $PIPELINE_REPO --body "<plan markdown>"' "$SKILL_FILE"; then
  fail_msg "old 'gh issue comment ... --body \"<plan markdown>\"' call still present"
else
  pass_msg "old direct gh issue comment call removed"
fi

echo "Test 6: imperative ownership on the post step (YOU MUST .* post-plan.sh)"
inc
if grep -qE "YOU MUST .*post-plan\.sh" "$SKILL_FILE"; then
  pass_msg "imperative 'YOU MUST .* post-plan.sh' present on the post step"
else
  fail_msg "post step lacks 'YOU MUST .* post-plan.sh' imperative ownership"
fi

echo "Test 7: no posting language inside any #### Task 0 — PATH X block"
inc
# Same extract_section helper pattern as test-plan-issue-path-tasks.sh, but
# also terminates at "^### ", "^## ", or a top-level numbered Step so PATH C
# (which is followed directly by Step 6, not another "#### ") does not
# over-capture Steps 6-8.
extract_path_block_strict() {
  local letter="$1"
  awk -v start="^#### Task 0 — PATH ${letter}" '
    $0 ~ start                                { inblock = 1; print; next }
    inblock && (/^#### / || /^### / || /^## / || /^[0-9]+\. \*\*/) { inblock = 0 }
    inblock                                   { print }
  ' "$SKILL_FILE"
}

POSTING_LEAK=0
for L in A B C; do
  BLK=$(extract_path_block_strict "$L")
  if echo "$BLK" | grep -qE "gh issue comment|post-plan\.sh"; then
    fail_msg "PATH ${L} Task 0 block contains posting language (post-plan.sh or 'gh issue comment') — must live in shared Steps 6-7 only"
    POSTING_LEAK=1
  fi
done
if [ "$POSTING_LEAK" -eq 0 ]; then
  pass_msg "no per-path block contains posting language"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
