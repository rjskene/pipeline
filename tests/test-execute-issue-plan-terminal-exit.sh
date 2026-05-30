#!/bin/bash
set -euo pipefail

# Prose-pin regression test for skills/execute-issue-plan/SKILL.md.
# Guards that the skill carries an explicit post-`pr-open` terminal-exit
# directive (Step 12) plus a matching Constraint, so future prose drift can't
# quietly reintroduce the post-PR lingering wedge documented in issue #631
# (agent holds the worktree + concurrency slot after the PR is already open).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL" ]; then
  echo "ERROR: SKILL.md not found at $SKILL" >&2
  exit 1
fi

echo "Case A: a terminal step exists after the pr-open step with a hard STOP directive"
inc
if grep -q "Step 12" "$SKILL" && grep -q "the agent's terminal state.*STOP" "$SKILL"; then
  pass_msg "Step 12 terminal-stop directive present"
else
  fail_msg "missing 'Step 12' and/or \"the agent's terminal state.*STOP\""
fi

echo "Case B: the terminal step names the pr-open trigger condition"
inc
if grep -q "once the .pr-open. label" "$SKILL" || grep -qiE "pr is (confirmed )?open" "$SKILL"; then
  pass_msg "terminal step gated on pr-open / PR-confirmed-open state"
else
  fail_msg "missing reference to the pr-open trigger / PR-confirmed-open state"
fi

echo "Case C: a Constraint bans a post-pr-open poll/wait/re-verify loop"
inc
if grep -qiE "after .*pr-open.*(do not|never).*(poll|wait|re-?verify|loop)" "$SKILL"; then
  pass_msg "Constraint bans post-pr-open poll/wait/re-verify loop"
else
  fail_msg "missing Constraint banning a post-pr-open poll/wait/re-verify loop"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
