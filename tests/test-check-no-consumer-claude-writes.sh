#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "lint script exists and is executable" "[ -x \"$REPO_ROOT/scripts/check-no-consumer-claude-writes.sh\" ]"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
