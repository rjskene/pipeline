#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$REPO_ROOT/docs/release-cadence.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# Doc-grep regression test (#524): forcing-function for the within-minor rc.N cadence language.
# release-please's version calculator is not hermetically invokable (reads the GitHub API, not
# local git), so the docs are the operator-facing contract for the cadence — guard against drift.
assert "docs note rc.N accumulates within a minor" "grep -qF 'rc.N iterates within the current minor' \"$DOCS\""
assert "docs note explicit Release-As: required to start next minor RC" "grep -qE 'Release-As: 0\\.[0-9]+\\.0-rc\\.1' \"$DOCS\""
assert "docs reference bump-patch-for-minor-pre-major: true" "grep -qF 'bump-patch-for-minor-pre-major: true' \"$DOCS\""

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
