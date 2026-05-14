#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUIDE="$REPO_ROOT/docs/migration-from-subtree.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
assert "guide file exists" "[ -f '$GUIDE' ]"
assert "references migrate-from-subtree.sh" "grep -q 'scripts/migrate-from-subtree.sh' '$GUIDE'"
assert "references marketplace add" "grep -qF '/plugin marketplace add HTS-COLLAB-ORG/claude-pipeline' '$GUIDE'"
assert "references plugin install" "grep -qF '/plugin install claude-pipeline' '$GUIDE'"
assert "references /pipeline:run for verify step" "grep -qF '/pipeline:run' '$GUIDE'"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
