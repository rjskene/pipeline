#!/bin/bash
set -uo pipefail

# Guard test for the PATH D dogfood fixture (#718).
# Sources sandbox/dogfood-fixtures/d2/echo.sh and asserts d2_echo prints
# exactly the literal "d2-ok".

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/../sandbox/dogfood-fixtures/d2/echo.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$FIXTURE" ]; then
  fail_msg "fixture exists at sandbox/dogfood-fixtures/d2/echo.sh"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# shellcheck source=/dev/null
. "$FIXTURE"

if [ "$(d2_echo)" = "d2-ok" ]; then
  pass_msg "d2_echo prints d2-ok"
else
  fail_msg "d2_echo prints d2-ok (got: $(d2_echo 2>&1))"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
