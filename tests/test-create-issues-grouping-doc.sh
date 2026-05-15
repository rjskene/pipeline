#!/bin/bash
set -uo pipefail
#
# Tests that skills/create-issues/SKILL.md documents the grouping-detection
# step introduced by issue #62: invokes find-grouping-candidates.sh, surfaces
# the three recommendation shapes, includes a user-confirmation gate, and
# documents the post-confirmation auto-append to a tracker's `## Rollout
# sequence` checklist.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/create-issues/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  fail_msg "SKILL.md exists at skills/create-issues/SKILL.md"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# (1) `### Grouping detection` heading exists.
grouping_line=$(grep -nE '^### Grouping detection' "$SKILL" | head -n 1 || true)
if [ -n "$grouping_line" ]; then
  pass_msg "### Grouping detection heading exists"
else
  fail_msg "### Grouping detection heading exists"
fi

# (2) Grouping-detection appears BEFORE `### Issue proposal format`.
grouping_lno=$(echo "$grouping_line" | cut -d: -f1)
proposal_lno=$(grep -nE '^### Issue proposal format' "$SKILL" | head -n 1 | cut -d: -f1 || true)
if [ -n "$grouping_lno" ] && [ -n "$proposal_lno" ] && [ "$grouping_lno" -lt "$proposal_lno" ]; then
  pass_msg "Grouping detection precedes Issue proposal format (lines $grouping_lno < $proposal_lno)"
else
  fail_msg "Grouping detection precedes Issue proposal format (grouping=$grouping_lno, proposal=$proposal_lno)"
fi

# Extract the grouping-detection section: lines between its heading and the next `### `.
section=$(awk '
  /^### Grouping detection/ { in_section = 1; print; next }
  in_section && /^### / { exit }
  in_section { print }
' "$SKILL")

# (3) Section mentions `find-grouping-candidates.sh`.
if echo "$section" | grep -q 'find-grouping-candidates.sh'; then
  pass_msg "section references find-grouping-candidates.sh by name"
else
  fail_msg "section references find-grouping-candidates.sh by name"
fi

# (4) Section documents all three recommendation shapes.
shapes_ok=1
echo "$section" | grep -q 'TRACKER' || shapes_ok=0
echo "$section" | grep -q 'GROUP' || shapes_ok=0
echo "$section" | grep -q 'STANDALONE' || shapes_ok=0
if [ "$shapes_ok" -eq 1 ]; then
  pass_msg "section documents TRACKER / GROUP / STANDALONE recommendation shapes"
else
  fail_msg "section documents TRACKER / GROUP / STANDALONE recommendation shapes"
fi

# (5) Section documents the auto-append behavior using `gh issue edit` against the tracker's
#     `## Rollout sequence` checklist.
if echo "$section" | grep -q 'gh issue edit' && echo "$section" | grep -q 'Rollout sequence'; then
  pass_msg "section documents auto-append via gh issue edit on Rollout sequence"
else
  fail_msg "section documents auto-append via gh issue edit on Rollout sequence"
fi

# (6) Section documents the user-confirmation gate (default: accept).
if echo "$section" | grep -qiE '(default[^.]*accept|accept[^.]*default)'; then
  pass_msg "section documents the user-confirmation gate with default=accept"
else
  fail_msg "section documents the user-confirmation gate with default=accept"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
