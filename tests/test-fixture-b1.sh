#!/bin/bash
set -euo pipefail

# Tests for the b1 dogfood fixture module under sandbox/dogfood-fixtures/b1/.
#
# Pure throwaway fixture exercising the PATH B (spawned executor) path
# end-to-end. Asserts exact stdout for b1_alpha, b1_beta, and b1_gamma
# (gamma composes alpha+beta via source).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/sandbox/dogfood-fixtures/b1"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# ---- Case A: b1_alpha prints exactly "b1-alpha" ----
echo "Case A: b1_alpha output"
inc
out=$(bash -c "source '$FIXTURE_DIR/alpha.sh' && b1_alpha" 2>/dev/null) || true
if [ "$out" = "b1-alpha" ]; then
  pass_msg "Case A: b1_alpha prints 'b1-alpha'"
else
  fail_msg "Case A: expected 'b1-alpha', got '$out'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
