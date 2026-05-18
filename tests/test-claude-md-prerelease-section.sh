#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$REPO_ROOT/CLAUDE.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# All greps are scoped to CLAUDE.md only (do not scan CHANGELOG.md, .claude/logs, .git)
assert "Dev/prerelease channel header present" "grep -q 'Dev/prerelease channel' '$F'"
assert "Release-As: trigger mentioned" "grep -q 'Release-As:' '$F'"
assert "auto-back-sync mentioned (replaces no-back-sync-for-RCs exception)" "grep -qE 'auto-back-sync|back-sync-release' '$F'"
assert "gh pr merge --squash --body-file mitigation present" "grep -q 'gh pr merge --squash --body-file' '$F'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
