#!/bin/bash
set -euo pipefail

# Prose-pin regression test for skills/execute-issue-plan/SKILL.md.
# Guards that the skill carries the constraint banning unbounded sentinel-file
# polls and names the sanctioned helper, so future prose drift can't quietly
# reintroduce the wedge documented in issue #463.

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

echo "Case A: SKILL.md bans unbounded sentinel-file polls"
inc
if grep -q "Never inline unbounded sentinel-file polls" "$SKILL"; then
  pass_msg "constraint string present"
else
  fail_msg "missing 'Never inline unbounded sentinel-file polls'"
fi

echo "Case B: SKILL.md references the sanctioned helper by path"
inc
if grep -q "scripts/wait-for-sentinel.sh" "$SKILL"; then
  pass_msg "helper path referenced"
else
  fail_msg "missing reference to scripts/wait-for-sentinel.sh"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
