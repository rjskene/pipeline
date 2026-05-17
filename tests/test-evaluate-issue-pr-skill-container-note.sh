#!/bin/bash
set -uo pipefail

# Lints skills/evaluate-issue-pr/SKILL.md for the issue-#218
# dispatch-agnostic prose.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/skills/evaluate-issue-pr/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found" >&2
  exit 1
fi

inc
if grep -q "dispatch is transparent to this skill" "$FILE"; then
  pass_msg "container-dispatch transparency note present"
else
  fail_msg "missing literal 'dispatch is transparent to this skill'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
