#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$REPO_ROOT/README.md"
PASS=0; FAIL=0
assert_in() { if grep -qF "$2" "$README"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
assert_in "analyze-issues entrypoint listed" "/pipeline:analyze-issues"
assert_in "supersession detection mentioned" "supersession"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
