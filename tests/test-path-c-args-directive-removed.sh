#!/bin/bash
set -euo pipefail
# Guard: the broken test must be deleted and no other file may reference
# the consumer-side args path it pointed at.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

echo "Test 1: tests/test-path-c-args-directive.sh has been removed"
inc
if [ -e "$REPO_ROOT/tests/test-path-c-args-directive.sh" ]; then
  fail_msg "tests/test-path-c-args-directive.sh still exists (must be deleted)"
else
  pass_msg "test file removed"
fi

echo "Test 2: no source file references the removed test or its args path"
inc
HITS=$(grep -rEn 'test-path-c-args-directive\.sh|c-execute-subagent-driven-development\.txt' \
  --include='*.sh' --include='*.yml' --include='*.yaml' \
  --include='*.py' --include='*.json' --include='*.md' \
  "$REPO_ROOT" 2>/dev/null \
  | grep -v "$(basename "$0")" \
  | grep -v "/\.git/" \
  | grep -v "/\.claude/logs/" \
  | grep -v "/CHANGELOG\.md:" \
  || true)
if [ -n "$HITS" ]; then
  fail_msg "unexpected references remain:"$'\n'"$HITS"
else
  pass_msg "no references found"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
