#!/usr/bin/env bash
# test-dedup-lines.sh — colocated tests for dedup-lines.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEDUP="$SCRIPT_DIR/dedup-lines.sh"

pass=0
fail=0

run_test() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    echo "  expected: $(echo "$expected" | cat -A)"
    echo "  actual:   $(echo "$actual" | cat -A)"
    fail=$((fail + 1))
  fi
}

# Test 1: order-preserving dedup — input b,a,b,c,a -> b,a,c
tmp=$(mktemp)
printf 'b\na\nb\nc\na\n' > "$tmp"
actual=$(bash "$DEDUP" "$tmp")
run_test "order-preserving dedup (b,a,b,c,a -> b,a,c)" "$(printf 'b\na\nc')" "$actual"
rm -f "$tmp"

# Test 2: empty file -> empty output, exit 0
tmp2=$(mktemp)
> "$tmp2"
actual2=$(bash "$DEDUP" "$tmp2")
run_test "empty file -> empty output" "" "$actual2"
rm -f "$tmp2"

# Test 3: whitespace-only file -> empty output, exit 0
tmp3=$(mktemp)
printf '   \n\t\n  \n' > "$tmp3"
actual3=$(bash "$DEDUP" "$tmp3")
run_test "whitespace-only file -> empty output" "" "$actual3"
rm -f "$tmp3"

# Test 4: no duplicates - order preserved
tmp4=$(mktemp)
printf 'x\ny\nz\n' > "$tmp4"
actual4=$(bash "$DEDUP" "$tmp4")
run_test "no duplicates - order preserved" "$(printf 'x\ny\nz')" "$actual4"
rm -f "$tmp4"

# Test 5: all same line - only first kept
tmp5=$(mktemp)
printf 'foo\nfoo\nfoo\n' > "$tmp5"
actual5=$(bash "$DEDUP" "$tmp5")
run_test "all duplicates - only first kept" "foo" "$actual5"
rm -f "$tmp5"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
