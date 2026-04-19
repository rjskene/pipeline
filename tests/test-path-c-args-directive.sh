#!/bin/bash
set -euo pipefail

# Verifies the PATH C execute args file references the new tdd-implementer
# subagent + sentinel scheme + escape hatch, and no longer contains the
# "Follow-up issue #327 will replace" placeholder line.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARGS_FILE="$SCRIPT_DIR/../../scripts/skill-args/c-execute-subagent-driven-development.txt"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$ARGS_FILE" ]; then
  echo "ERROR: args file not found at $ARGS_FILE" >&2
  exit 1
fi

CONTENT=$(cat "$ARGS_FILE")

echo "Test 1: references tdd-implementer subagent type"
inc
if echo "$CONTENT" | grep -qE "subagent_type=['\"]?tdd-implementer['\"]?"; then
  pass_msg "tdd-implementer mentioned"
else
  fail_msg "expected Agent(subagent_type='tdd-implementer') reference"
fi

echo "Test 2: mandates target=<dir> sentinel"
inc
if echo "$CONTENT" | grep -q 'target='; then
  pass_msg "target= sentinel mentioned"
else
  fail_msg "expected 'target=' sentinel mandate"
fi

echo "Test 3: references enforce-path-c-delegation hook"
inc
if echo "$CONTENT" | grep -q 'enforce-path-c-delegation'; then
  pass_msg "hook referenced"
else
  fail_msg "expected reference to .claude/hooks/enforce-path-c-delegation.py"
fi

echo "Test 4: documents ALLOW_ORCHESTRATOR_EDIT escape hatch"
inc
if echo "$CONTENT" | grep -q 'ALLOW_ORCHESTRATOR_EDIT'; then
  pass_msg "escape hatch documented"
else
  fail_msg "expected ALLOW_ORCHESTRATOR_EDIT in escape-hatch text"
fi

echo "Test 5: 'Follow-up issue #327 will replace' placeholder is gone"
inc
if echo "$CONTENT" | grep -q 'Follow-up issue #327 will replace'; then
  fail_msg "placeholder still present; should be removed now that #327 is implemented"
else
  pass_msg "placeholder removed"
fi

echo "Test 6: forbids superpowers:finishing-a-development-branch"
inc
if echo "$CONTENT" | grep -q 'superpowers:finishing-a-development-branch'; then
  pass_msg "explicitly tells subagent not to invoke finishing skill"
else
  fail_msg "expected reference to superpowers:finishing-a-development-branch (do NOT invoke)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
