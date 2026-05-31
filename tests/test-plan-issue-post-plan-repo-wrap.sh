#!/bin/bash
set -euo pipefail
# Guard: the Step 7 post-plan.sh invocation in plan-issue SKILL.md MUST
# carry a PIPELINE_REPO= env prefix so the var propagates into the
# subagent subshell (regression guard for #709 / #716 wrinkle 1).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$SCRIPT_DIR/../skills/plan-issue/SKILL.md"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

inc
if grep -qE 'PIPELINE_REPO="\$PIPELINE_REPO" bash "\$\{CLAUDE_PLUGIN_ROOT:-\.\}/scripts/post-plan\.sh"' "$SKILL"; then
  pass_msg "Step 7 post-plan.sh invocation carries PIPELINE_REPO= prefix"
else
  fail_msg "Step 7 post-plan.sh invocation missing PIPELINE_REPO= prefix"
fi

# No bare (un-prefixed) post-plan.sh invocation line should remain.
inc
if grep -nE '^\s*bash "\$\{CLAUDE_PLUGIN_ROOT:-\.\}/scripts/post-plan\.sh"' "$SKILL" >/dev/null; then
  fail_msg "found a bare post-plan.sh invocation with no PIPELINE_REPO= prefix"
else
  pass_msg "no bare post-plan.sh invocation remains"
fi

echo ""; echo "  $PASS/$TESTS passed"
[ "$FAIL" -eq 0 ] || exit 1
