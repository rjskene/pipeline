#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$REPO_ROOT/docs/release-cadence.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# Two-branch model with release-please — content lives in docs/release-cadence.md
assert "Release cadence header exists" "grep -qE '^# Release cadence' '$DOC'"
assert "mentions release-please" "grep -qiE 'release-please' '$DOC'"
assert "documents auto Release PR on push to main" "grep -qE 'Release PR.*main|main.*Release PR' '$DOC'"
assert "documents plugin reload note retained" "grep -qE '/plugin (un)?install pipeline@claude-pipeline' '$DOC'"
assert "describes staging as dev trunk" "grep -qiE 'staging[^\\n]*dev trunk|dev trunk[^\\n]*staging' '$DOC'"
assert "mentions merge-based back-sync to staging" "grep -qiE 'merges the release commit onto staging' '$DOC'"

# Branches section is kept in CLAUDE.md (load-bearing rule)
assert "CLAUDE.md Branches section mentions staging" "grep -qE '\`staging\`' '$CLAUDE_MD'"
assert "CLAUDE.md Branches section mentions main" "grep -qE '\`main\`' '$CLAUDE_MD'"
assert "CLAUDE.md points to docs/release-cadence.md" "grep -q 'docs/release-cadence.md' '$CLAUDE_MD'"

# Legacy pre-#106 manual ritual must stay gone (check both files)
assert "removes 'release/vX.Y.Z' branch ritual (docs)" "! grep -qE 'release/vX\\.Y\\.Z' '$DOC'"
assert "removes 'chore/sync-vX.Y.Z-to-staging' wording (docs)" "! grep -qE 'chore/sync-vX\\.Y\\.Z-to-staging' '$DOC'"
assert "removes 'release/vX.Y.Z' branch ritual (claude.md)" "! grep -qE 'release/vX\\.Y\\.Z' '$CLAUDE_MD'"
assert "removes 'chore/sync-vX.Y.Z-to-staging' wording (claude.md)" "! grep -qE 'chore/sync-vX\\.Y\\.Z-to-staging' '$CLAUDE_MD'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
