#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/repeat.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

result=$(repeat_str x 3)
[ "$result" = "xxx" ] || fail "repeat_str x 3 expected 'xxx', got '$result'"

result=$(repeat_str ab 0)
[ "$result" = "" ] || fail "repeat_str ab 0 expected empty, got '$result'"

echo "ALL TESTS PASSED"
