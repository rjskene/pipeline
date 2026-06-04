#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/clamp.sh"

fail=0

result=$(clamp 5 0 3)
if [[ "$result" != "3" ]]; then
  echo "FAIL: clamp 5 0 3 => '$result', expected '3'" >&2
  fail=1
fi

result=$(clamp -1 0 3)
if [[ "$result" != "0" ]]; then
  echo "FAIL: clamp -1 0 3 => '$result', expected '0'" >&2
  fail=1
fi

result=$(clamp 2 0 3)
if [[ "$result" != "2" ]]; then
  echo "FAIL: clamp 2 0 3 => '$result', expected '2'" >&2
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "All tests passed."
fi

exit $fail
