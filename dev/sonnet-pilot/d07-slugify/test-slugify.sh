#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slugify.sh"

fail() { echo "FAIL: $1"; exit 1; }

result=$(slugify 'Hello World')
[ "$result" = "hello-world" ] || fail "Expected 'hello-world', got '$result'"

result=$(slugify 'A  B')
[ "$result" = "a-b" ] || fail "Expected 'a-b', got '$result'"

echo "All tests passed."
