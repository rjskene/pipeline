#!/bin/bash
set -euo pipefail

# Tests for the b2 dogfood fixtures (sandbox/dogfood-fixtures/b2/).
# Asserts each fixture function's output and zeta's concatenation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
B2_DIR="$REPO_ROOT/sandbox/dogfood-fixtures/b2"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Task 1: b2_delta
# shellcheck source=/dev/null
. "$B2_DIR/delta.sh"
out="$(b2_delta)"
if [ "$out" = "b2-delta" ]; then
  pass_msg "b2_delta outputs b2-delta"
else
  fail_msg "b2_delta outputs b2-delta (got: $out)"
fi

# Task 2: b2_epsilon
# shellcheck source=/dev/null
. "$B2_DIR/epsilon.sh"
out="$(b2_epsilon)"
if [ "$out" = "b2-epsilon" ]; then
  pass_msg "b2_epsilon outputs b2-epsilon"
else
  fail_msg "b2_epsilon outputs b2-epsilon (got: $out)"
fi

# Task 3: b2_zeta (sources delta + epsilon)
# shellcheck source=/dev/null
. "$B2_DIR/zeta.sh"
out="$(b2_zeta)"
if [ "$out" = "b2-delta b2-epsilon b2-zeta" ]; then
  pass_msg "b2_zeta outputs b2-delta b2-epsilon b2-zeta"
else
  fail_msg "b2_zeta outputs b2-delta b2-epsilon b2-zeta (got: $out)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
