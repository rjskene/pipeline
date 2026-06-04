#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/wc.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

result=$(count_words 'a b c')
[ "$result" = "3" ] || fail "count_words 'a b c' expected 3, got '$result'"

result=$(count_words '')
[ "$result" = "0" ] || fail "count_words '' expected 0, got '$result'"

echo "All tests passed."
