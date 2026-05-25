#!/bin/bash
set -euo pipefail
# Regression guard for issue #459 (Blocker 2 / R4): the back-sync-release
# workflow trigger must survive the squash->merge-commit migration.
#
# Under squash-merge of release-please's Release PR, the pushed head_commit
# subject was `chore(main): release X.Y.Z (#NNN)` and `startsWith(...)` matched.
# Under `gh pr merge --merge`, the default head_commit SUBJECT becomes
# `Merge pull request #NNN from ...` and the `chore(main): release X.Y.Z` text
# lands in the BODY portion of head_commit.message. `startsWith()` only inspects
# the subject and would silently disable back-sync after every release;
# `contains()` matches whether the token is in the subject (squash legacy) or
# the body (merge-commit), so it survives both regimes.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/back-sync-release.yml"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "workflow file exists" "[ -f '$WF' ]"

# Must use contains() on head_commit.message with the release token.
assert "trigger uses contains(github.event.head_commit.message, 'chore(main): release ')" \
  "grep -qF \"contains(github.event.head_commit.message, 'chore(main): release ')\" '$WF'"

# Must NOT use the subject-only startsWith() form (the bug this guards against).
assert "trigger does NOT use startsWith(github.event.head_commit.message, ...)" \
  "! grep -qF \"startsWith(github.event.head_commit.message, 'chore(main): release ')\" '$WF'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
