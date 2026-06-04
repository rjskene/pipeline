#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/reverse.sh"

pass=0
fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc — expected '$expected', got '$actual'"
    fail=$((fail + 1))
  fi
}

assert_eq "rev_str abc prints cba" "cba" "$(rev_str abc)"
assert_eq "rev_str a prints a"     "a"   "$(rev_str a)"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
