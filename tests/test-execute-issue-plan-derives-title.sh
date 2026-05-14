#!/bin/bash
# Tests that skills/execute-issue-plan/SKILL.md uses scripts/derive-pr-title.sh
# to derive the PR title instead of passing the raw issue title through.
# See issue #56 and tests/test-derive-pr-title.sh for the helper itself.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  echo "ERROR: skill file not found: $SKILL" >&2
  exit 1
fi

# (a) The skill invokes the helper.
if grep -q 'scripts/derive-pr-title.sh' "$SKILL"; then
  pass_msg "skill invokes scripts/derive-pr-title.sh"
else
  fail_msg "skill invokes scripts/derive-pr-title.sh" "string not found in $SKILL"
fi

# (b) The skill no longer passes the raw issue title through to gh pr create.
if grep -qF -e '--title "<issue title>"' "$SKILL"; then
  fail_msg "skill no longer passes raw issue title to --title" "literal '--title \"<issue title>\"' still present"
else
  pass_msg "skill no longer passes raw issue title to --title"
fi

# (c) The skill documents the tracker refusal path.
if grep -qE 'exit 2|tracker \(epic title\)' "$SKILL"; then
  pass_msg "skill documents tracker refusal path"
else
  fail_msg "skill documents tracker refusal path" "neither 'exit 2' nor 'tracker (epic title)' found"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
