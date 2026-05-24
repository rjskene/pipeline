#!/bin/bash
set -euo pipefail
# Regression guard for issue #475: graduation guidance must require either a
# `Release-As:` footer on the squash merge OR a non-squash merge-commit, and
# must NOT regress to the old "no-footer cut produces stable" promise (which
# silently fails because the squash subject is not a Conventional Commit type
# and release-please emits "No user facing commits found").
#
# Scope: docs/release-cadence.md only. Do NOT scan CHANGELOG.md, .claude/logs/,
# or .git/ — per MEMORY.md feedback_release_fragile_tests.md.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$REPO_ROOT/docs/release-cadence.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# 1. Graduation heading/bullet still present.
assert "Graduation heading/bullet present" "grep -qE '\\*\\*Graduation' '$F'"

# 2. Both options named: Release-As footer AND merge-commit alternative.
assert "Release-As: footer mentioned in graduation guidance" "grep -q 'Release-As:' '$F'"
assert "merge-commit alternative mentioned" "grep -qE 'merge[- ]commit' '$F'"

# 3. Forbid regression to legacy promise.
assert "legacy 'WITHOUT a Release-As: footer produces the stable' promise removed" \
  "! grep -qE 'WITHOUT a .Release-As:. footer produces the stable' '$F'"

# 4. Silent-skip failure mode explicitly called out.
assert "silent-skip failure mode named" \
  "grep -qE 'silently fail|silently skip|silent skip|No user facing commits found|release-please will skip|release-please skip' '$F'"

# 5. Recovery sub-bullet present with follow-up Release-As chore PR mention.
assert "Recovery sub-bullet present" "grep -qE '\\*\\*Recovery' '$F'"
assert "Recovery references follow-up Release-As chore PR" \
  "awk '/\\*\\*Recovery/,/^[0-9]+\\./' '$F' | grep -q 'Release-As:'"

# 6. Cross-reference to the sticky-prerelease-flag flip retained.
assert "post-tag gh release edit --prerelease=false --latest flip retained" \
  "grep -q 'prerelease=false' '$F' && grep -q -- '--latest' '$F'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
