#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$REPO_ROOT/CLAUDE.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# Two-branch model with release-please
assert "Release cadence section exists" "grep -qE '^### Release cadence' '$DOC'"
assert "mentions release-please" "grep -qiE 'release-please' '$DOC'"
assert "documents auto Release PR on push to main" "grep -qE 'Release PR.*main|main.*Release PR' '$DOC'"
assert "documents plugin reload note retained" "grep -qE '/plugin (un)?install pipeline@claude-pipeline' '$DOC'"
assert "describes staging as dev trunk" "grep -qiE 'staging[^\\n]*dev trunk|dev trunk[^\\n]*staging' '$DOC'"
assert "mentions merge-based back-sync to staging" "grep -qiE 'merges the release commit onto staging' '$DOC'"
assert "Branches section mentions staging" "grep -qE '\`staging\`' '$DOC'"
assert "Branches section mentions main" "grep -qE '\`main\`' '$DOC'"

# Legacy pre-#106 manual ritual must stay gone
assert "removes 'release/vX.Y.Z' branch ritual" "! grep -qE 'release/vX\\.Y\\.Z' '$DOC'"
assert "removes 'chore/sync-vX.Y.Z-to-staging' wording" "! grep -qE 'chore/sync-vX\\.Y\\.Z-to-staging' '$DOC'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
