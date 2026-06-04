#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/upper.sh"

fail=0

result=$(to_upper ab)
if [[ "$result" != "AB" ]]; then
  echo "FAIL: to_upper ab => '$result' (expected 'AB')"
  fail=1
fi

result=$(to_upper aB3)
if [[ "$result" != "AB3" ]]; then
  echo "FAIL: to_upper aB3 => '$result' (expected 'AB3')"
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "PASS"
fi
exit $fail
