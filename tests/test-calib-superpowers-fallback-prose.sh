#!/usr/bin/env bash
# test-calib-superpowers-fallback-prose.sh — backlog #11 Block B (#1412).
#
# CLAUDE.md principle 3 promises inline fallback when a superpowers skill
# isn't installed, but before #1412 the three call sites
# (skills/plan-issue/SKILL.md Step 5 + Task N, skills/execute-issue-plan/
# SKILL.md Step 8a) prescribed Skill(skill: "superpowers:...") with no
# fallback sentence, so the --superpowers off calibration arm would measure
# error recovery instead of inline behaviour. These are the static greps
# pinning the three fallback sentences into place (one per call site).
#
# Static-only: reads tracked sources, runs nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLAN_SKILL="$ROOT/skills/plan-issue/SKILL.md"
EXECUTE_SKILL="$ROOT/skills/execute-issue-plan/SKILL.md"

FAILED=0
fail() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
pass() { echo "  PASS: $*"; }

require_file() {
  if [ -f "$1" ]; then return 0; fi
  fail "$2: $1 does not exist"
  return 1
}

echo "=== (a) plan-issue Step 5: writing-plans fallback ==="
if require_file "$PLAN_SKILL" "(a)"; then
  if grep -qF 'If `superpowers:writing-plans` is unavailable, draft the plan inline' "$PLAN_SKILL"; then
    pass "(a) Step 5 names the writing-plans inline fallback"
  else
    fail "(a) Step 5 does not name the writing-plans inline fallback"
  fi
fi

echo "=== (b) plan-issue Task N: requesting-code-review fallback ==="
if require_file "$PLAN_SKILL" "(b)"; then
  if grep -qF 'If `superpowers:requesting-code-review` is unavailable, run the self-check inline' "$PLAN_SKILL"; then
    pass "(b) Task N names the requesting-code-review inline fallback"
  else
    fail "(b) Task N does not name the requesting-code-review inline fallback"
  fi
fi

echo "=== (c) execute-issue-plan Step 8a: requesting-code-review fallback ==="
if require_file "$EXECUTE_SKILL" "(c)"; then
  if grep -qF 'If unavailable, run this self-check inline against the plan comment body' "$EXECUTE_SKILL"; then
    pass "(c) Step 8a names the requesting-code-review inline fallback"
  else
    fail "(c) Step 8a does not name the requesting-code-review inline fallback"
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
