#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/release-please.yml"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "release-please workflow exists" "[ -f '$WF' ]"
assert "workflow triggers on push to main" "grep -qE '^[[:space:]]*branches:[[:space:]]*\[[[:space:]]*main[[:space:]]*\]' '$WF'"
assert "workflow uses googleapis/release-please-action@v4" "grep -qE 'googleapis/release-please-action@v4' '$WF'"
assert "workflow declares contents: write permission" "grep -qE 'contents:[[:space:]]*write' '$WF'"
assert "workflow declares pull-requests: write permission" "grep -qE 'pull-requests:[[:space:]]*write' '$WF'"
assert "workflow uses manifest mode (manifest-file input)" "grep -qE 'manifest-file:' '$WF'"
assert "workflow points to release-please-config.json" "grep -qE 'config-file:[[:space:]]*release-please-config\.json' '$WF'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
