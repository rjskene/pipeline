#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$REPO_ROOT/CLAUDE.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# New wording present
assert "Release cadence section exists" "grep -qE '^### Release cadence' '$DOC'"
assert "mentions release-please" "grep -qiE 'release-please' '$DOC'"
assert "documents auto Release PR on push to main" "grep -qE 'Release PR.*main|main.*Release PR' '$DOC'"
assert "documents plugin reload note retained" "grep -qE '/plugin (un)?install pipeline@claude-pipeline' '$DOC'"

# Old manual procedure removed
assert "removes 'Back-sync to staging' wording" "! grep -qE 'Back-sync to staging' '$DOC'"
assert "removes 'release/vX.Y.Z' branch ritual" "! grep -qE 'release/vX\\.Y\\.Z' '$DOC'"
assert "removes 'chore/sync-vX.Y.Z-to-staging' wording" "! grep -qE 'chore/sync-vX\\.Y\\.Z-to-staging' '$DOC'"

# Branches section updated for Option B
assert "Branches section reflects main as base" "grep -qE 'PIPELINE_BASE_BRANCH.*main|main.*PIPELINE_BASE_BRANCH' '$DOC'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
