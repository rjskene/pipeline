#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=add.sh
source "$SCRIPT_DIR/add.sh"

fail=0

result=$(add 2 3)
if [[ "$result" != "5" ]]; then
  echo "FAIL: add 2 3 expected 5, got $result"
  fail=1
else
  echo "PASS: add 2 3 = 5"
fi

result=$(add -1 1)
if [[ "$result" != "0" ]]; then
  echo "FAIL: add -1 1 expected 0, got $result"
  fail=1
else
  echo "PASS: add -1 1 = 0"
fi

exit "$fail"
