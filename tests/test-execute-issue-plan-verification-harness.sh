#!/bin/bash
set -uo pipefail

# Prose-pin regression test for skills/execute-issue-plan/SKILL.md Step 6b.
# Guards that the executor's test-verification phase is hardened against the
# class of failure in issue #677: an ad-hoc unbounded `for t in tests/test*.sh`
# sweep that (a) pulls in unrelated, possibly-interactive tests, (b) hangs the
# executor on an unguarded `read`, and (c) is launched concurrently with itself
# so stub/temp-file-sharing tests collide and report spurious failures.
#
# The durable fix lives in the verification harness (Step 6b prose) plus a
# mirrored Constraint — modeled on tests/test-execute-issue-plan-terminal-exit.sh
# (the Step 12 + Constraint dual-pin pattern). Future prose drift can't quietly
# reintroduce the unguarded/concurrent sweep without tripping these cases.

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

# Step 6b region: from the "**6b." heading up to (but not including) "**6c.".
SIXB="$(awk '/\*\*6b\./{f=1} /\*\*6c\./{f=0} f' "$SKILL")"
# Constraints section: from "## Constraints" to EOF.
CONSTRAINTS="$(awk '/^## Constraints/{f=1} f' "$SKILL")"

echo "Case A: Step 6b runs \$PIPELINE_TEST_CMD and forbids an unbounded for-t sweep"
inc
if echo "$SIXB" | grep -q 'PIPELINE_TEST_CMD' \
   && echo "$SIXB" | grep -qiE 'targeted|relevant' \
   && echo "$SIXB" | grep -qiE 'do NOT|never' \
   && echo "$SIXB" | grep -qiE 'unbounded|for t in'; then
  pass_msg "6b scopes verification to \$PIPELINE_TEST_CMD (targeted/relevant) and bans the for-t sweep"
else
  fail_msg "6b must run \$PIPELINE_TEST_CMD (targeted/relevant) AND forbid an unbounded 'for t in' sweep"
fi

echo "Case B: Step 6b mandates stdin redirection and a timeout guard"
inc
if echo "$SIXB" | grep -q '</dev/null' \
   && echo "$SIXB" | grep -qi 'timeout'; then
  pass_msg "6b mandates </dev/null AND timeout"
else
  fail_msg "6b must contain the literal </dev/null AND the word timeout"
fi

echo "Case C: Step 6b / Constraints forbid concurrent full-suite verification runs"
inc
if grep -qi 'concurrent' "$SKILL" \
   && grep -qiE 'single|sequential' "$SKILL" \
   && grep -qiE 'verification|suite' "$SKILL"; then
  pass_msg "no-concurrent + single/sequential + verification/suite prose present"
else
  fail_msg "missing prose forbidding concurrent (single/sequential) verification/suite runs"
fi

echo "Case D: a Constraint restates the no-unguarded-sweep / no-concurrent rule"
inc
if echo "$CONSTRAINTS" | grep -qiE 'for t in tests/test' \
   && echo "$CONSTRAINTS" | grep -qi 'concurrent' \
   && echo "$CONSTRAINTS" | grep -qE '</dev/null|timeout'; then
  pass_msg "Constraint pins single-pass \$PIPELINE_TEST_CMD + no for-t sweep + no concurrent runs"
else
  fail_msg "Constraints must restate: no unbounded 'for t in tests/test' sweep, no concurrent runs, </dev/null+timeout"
fi

echo "Case E: Step 6b reinforces the red->green->commit gate (own targeted test must be green)"
inc
if echo "$SIXB" | grep -qi 'targeted test' \
   && echo "$SIXB" | grep -qi 'green' \
   && echo "$SIXB" | grep -qiE 'never commit past a red|red.*targeted|targeted test.*red'; then
  pass_msg "6b pins the issue's own targeted test must be green before verification"
else
  fail_msg "6b must reinforce: the issue's OWN targeted test must be green; never commit past a red targeted test"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
