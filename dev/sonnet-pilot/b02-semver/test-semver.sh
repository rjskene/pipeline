#!/usr/bin/env bash
# TDD test suite for semver_cmp
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/semver.sh"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"
    (( PASS++ )) || true
  else
    echo "FAIL: $desc — expected '$expected', got '$actual'"
    (( FAIL++ )) || true
  fi
}

# Numeric field compare: 1.2.0 < 1.10.0 (10 > 2 numerically)
assert_eq "1.2.0 < 1.10.0" "-1" "$(semver_cmp 1.2.0 1.10.0)"

# v-prefix stripping: v1.0.0 == 1.0.0
assert_eq "v1.0.0 == 1.0.0" "0" "$(semver_cmp v1.0.0 1.0.0)"

# Major dominates: 2.0.0 > 1.9.9
assert_eq "2.0.0 > 1.9.9" "1" "$(semver_cmp 2.0.0 1.9.9)"

# Patch compare: 1.0.1 > 1.0.0
assert_eq "1.0.1 > 1.0.0" "1" "$(semver_cmp 1.0.1 1.0.0)"

# Additional edge cases
# Equal versions
assert_eq "1.5.3 == 1.5.3" "0" "$(semver_cmp 1.5.3 1.5.3)"

# V-prefix (uppercase)
assert_eq "V2.0.0 == 2.0.0" "0" "$(semver_cmp V2.0.0 2.0.0)"

# a < b on minor
assert_eq "1.9.0 < 1.10.0" "-1" "$(semver_cmp 1.9.0 1.10.0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
