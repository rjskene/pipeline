#!/bin/bash
set -uo pipefail

# Guard test for the PATH D dogfood fixture (#709).
# Sources sandbox/dogfood-fixtures/d1/quick.sh and asserts d1_quick prints
# exactly the literal "d1-ok".

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/../sandbox/dogfood-fixtures/d1/quick.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$FIXTURE" ]; then
  fail_msg "fixture exists at sandbox/dogfood-fixtures/d1/quick.sh"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# shellcheck source=/dev/null
. "$FIXTURE"

if [ "$(d1_quick)" = "d1-ok" ]; then
  pass_msg "d1_quick prints d1-ok"
else
  fail_msg "d1_quick prints d1-ok (got: $(d1_quick 2>&1))"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
