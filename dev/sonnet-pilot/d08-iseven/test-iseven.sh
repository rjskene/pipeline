#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/iseven.sh"

fail=0

is_even 4 && echo "PASS: is_even 4 exits 0" || { echo "FAIL: is_even 4 should exit 0"; fail=1; }

is_even 3 && { echo "FAIL: is_even 3 should exit 1"; fail=1; } || echo "PASS: is_even 3 exits 1"

is_even 0 && echo "PASS: is_even 0 exits 0" || { echo "FAIL: is_even 0 should exit 0"; fail=1; }

exit $fail
