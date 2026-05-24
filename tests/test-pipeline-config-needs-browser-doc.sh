#!/bin/bash
set -euo pipefail
# Guard: pipeline.config.example must document that execute-issue-plan is
# permitted under --container-mode when the issue carries the needs-browser
# label (label gate in spawn-claude.sh, issue #368).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE="$REPO_ROOT/pipeline.config.example"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

assert_contains() {
  local needle="$1"; local label="$2"
  inc
  if grep -qF -- "$needle" "$FILE"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

echo "pipeline.config.example needs-browser executor-container documentation"

assert_contains "needs-browser" "documents the needs-browser label"
assert_contains "#368" "references issue #368"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
