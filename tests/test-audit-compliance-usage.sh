#!/bin/bash
set -uo pipefail

# Task 7 (issue #417): usage guardrail — invoking the script with fewer than
# two positional arguments must exit non-zero and print the canonical usage
# line to stderr.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/audit-compliance.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SCRIPT" ]; then
  fail_msg "script exists at scripts/audit-compliance.sh"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# No args.
ERR="$(bash "$SCRIPT" 2>&1 1>/dev/null)"
RC=$?

if [ "$RC" -ne 0 ]; then
  pass_msg "no-args invocation exits non-zero (rc=$RC)"
else
  fail_msg "no-args invocation exits non-zero (got rc=$RC)"
fi

EXPECTED="Usage: audit-compliance.sh <issue> <pr> [--dry-run] [--files-json F] [--commits-json F] [--labels-json F]"
if echo "$ERR" | grep -qF "$EXPECTED"; then
  pass_msg "stderr contains canonical usage line"
else
  fail_msg "stderr contains canonical usage line (got: $ERR)"
fi

# One arg also fails.
ERR1="$(bash "$SCRIPT" 999 2>&1 1>/dev/null)"
RC1=$?
if [ "$RC1" -ne 0 ]; then
  pass_msg "one-arg invocation exits non-zero (rc=$RC1)"
else
  fail_msg "one-arg invocation exits non-zero (got rc=$RC1)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
