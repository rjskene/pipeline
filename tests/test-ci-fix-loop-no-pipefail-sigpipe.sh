#!/usr/bin/env bash
# Regression guard: tests/test-ci-fix-loop.sh must contain ZERO occurrences of
# the SIGPIPE-prone pattern `echo "$VAR" | grep -q`.
#
# Under set -uo pipefail, grep -q can match-and-exit before echo finishes
# writing, causing echo to die on SIGPIPE -> the pipeline exits 141 -> the if
# guard wrongly takes the else branch and fires fail_msg even though the
# pattern matched. Converting to here-strings (`grep -q PAT <<<"$VAR"`)
# eliminates the pipe and the race entirely.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/test-ci-fix-loop.sh"

PASS=0; FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if [ ! -f "$TARGET" ]; then
  fail_msg "target file exists: $TARGET"
  echo "Tests: 1  Pass: $PASS  Fail: $FAIL"
  exit 1
fi

# Count occurrences of: echo "$<VAR>" | grep -q
count=$(grep -cE 'echo "\$[A-Za-z_0-9]+" \| grep -q' "$TARGET" || true)

if [ "$count" -eq 0 ]; then
  pass_msg "zero SIGPIPE-prone echo|grep-q pipes in test-ci-fix-loop.sh"
else
  fail_msg "found $count SIGPIPE-prone echo|\`grep -q\` pipe(s) in test-ci-fix-loop.sh — convert to here-strings"
fi

echo "Tests: 1  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
