#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$REPO_ROOT/docs/release-cadence.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# Absence checks — strings retired by the linear-stable cadence (#610).
# Scope is docs/release-cadence.md + CLAUDE.md only — never CHANGELOG.md, .git, .claude/logs
# (per feedback_release_fragile_tests memory).
assert "docs/release-cadence.md does not mention Release-As:" "! grep -qF 'Release-As:' '$DOCS'"
assert "docs/release-cadence.md does not contain Dev/prerelease channel header" "! grep -qF 'Dev/prerelease channel' '$DOCS'"
assert "docs/release-cadence.md does not contain -rc. version literals" "! grep -qF -- '-rc.' '$DOCS'"
assert "docs/release-cadence.md does not mention prerelease-type" "! grep -qF 'prerelease-type' '$DOCS'"
assert "docs/release-cadence.md does not contain manual cut prose" "! grep -qF 'manual cut' '$DOCS'"
assert "CLAUDE.md no longer mentions prerelease channel" "! grep -qF 'prerelease channel' '$CLAUDE_MD'"

# Presence checks — the new Version-bump policy subsection.
assert "docs/release-cadence.md contains Version-bump policy section" "grep -qF 'Version-bump policy' '$DOCS'"
assert "docs/release-cadence.md names bump-minor-pre-major: true" "grep -qF 'bump-minor-pre-major: true' '$DOCS'"
assert "docs/release-cadence.md names bump-patch-for-minor-pre-major: true" "grep -qF 'bump-patch-for-minor-pre-major: true' '$DOCS'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
