#!/bin/bash
set -euo pipefail
# Guard: evaluate-issue-plan and plan-issue SKILL.md files must both carry the
# README anchor guard prose (#1035 / #397/#404 policy). The evaluator must
# return Revise when a plan prescribes anchored README cross-references; the
# planner must not draft them in the first place.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVAL_SKILL="$REPO_ROOT/skills/evaluate-issue-plan/SKILL.md"
PLAN_SKILL="$REPO_ROOT/skills/plan-issue/SKILL.md"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

assert_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  inc
  if grep -qF -- "$needle" "$file"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

echo "README anchor guard prose — evaluate-issue-plan"

# evaluator: guard bullet present in Phase 1
assert_contains "$EVAL_SKILL" "README anchor guard" \
  "evaluate-issue-plan: guard bullet present"
# evaluator: references the regex pattern
assert_contains "$EVAL_SKILL" '\.md#[A-Za-z0-9_-]+' \
  "evaluate-issue-plan: anchor regex present"
# evaluator: instructs Revise verdict
assert_contains "$EVAL_SKILL" "return **Revise**" \
  "evaluate-issue-plan: instructs Revise verdict"
# evaluator: cites the enforcing test
assert_contains "$EVAL_SKILL" "test-readme-current.sh" \
  "evaluate-issue-plan: cites test-readme-current.sh"

echo ""
echo "README anchor guard prose — plan-issue"

# planner: guard note present in step 4
assert_contains "$PLAN_SKILL" "README anchor guard" \
  "plan-issue: guard note present"
# planner: references the regex pattern
assert_contains "$PLAN_SKILL" '\.md#[A-Za-z0-9_-]+' \
  "plan-issue: anchor regex present"
# planner: cites the enforcing test
assert_contains "$PLAN_SKILL" "test-readme-current.sh" \
  "plan-issue: cites test-readme-current.sh"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
