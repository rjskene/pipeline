#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/trim.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

result=$(trim '  hi  ')
[ "$result" = "hi" ] || fail "trim '  hi  ' expected 'hi' got '$result'"

result=$(trim 'a b')
[ "$result" = "a b" ] || fail "trim 'a b' expected 'a b' got '$result'"

echo "ALL TESTS PASSED"
