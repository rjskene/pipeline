#!/bin/bash
set -euo pipefail

# Guard: skills/run/SKILL.md must NOT invoke the three retired startup-prompt
# scripts. The startup prompts (steps 1, 1b, 1c in the legacy numbering) were
# stripped per issue #317 — `/pipeline:run` now leads with the issue status
# table per `feedback_pipeline_run_prioritization_first`. `review-logs.sh` and
# `review-audits.sh` remain shipped for inspect-on-demand use, but the skill
# prose must not fire them.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_PATH="$SCRIPT_DIR/../skills/status/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_PATH" ]; then
  fail_msg "SKILL.md not found at $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

for SCRIPT in review-logs.sh review-audits.sh should-dispatch-audit.sh; do
  inc
  if grep -qF "$SCRIPT" "$SKILL_PATH"; then
    fail_msg "skills/run/SKILL.md still references $SCRIPT (should be stripped per #317)"
  else
    pass_msg "skills/run/SKILL.md contains no $SCRIPT invocation"
  fi
done

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
