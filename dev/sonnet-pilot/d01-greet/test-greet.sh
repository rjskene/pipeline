#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=greet.sh
source "$SCRIPT_DIR/greet.sh"

pass=0 fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"
    pass=$((pass+1))
  else
    echo "FAIL: $desc — expected '$expected', got '$actual'"
    fail=$((fail+1))
  fi
}

assert_eq "greet world" "hello, world" "$(greet world)"
assert_eq "greet (no arg)" "hello, world" "$(greet)"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
