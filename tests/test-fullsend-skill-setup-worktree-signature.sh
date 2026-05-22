#!/bin/bash
# Asserts that skills/fullsend/SKILL.md step 5 documents the full
# setup-worktree.sh invocation signature: both positional args
# (branch-name + issue-number), a worked example, and an explicit
# callout against passing only the issue number.
#
# Introduced by issue #350.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_PATH="$SCRIPT_DIR/../skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_PATH" ]; then
  fail_msg "SKILL.md not found at $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

# Locate step 5 anchor — the "Set up worktrees" numbered list item.
STEP5_LINE=$(grep -nE '^5\. \*\*Set up worktrees\*\*' "$SKILL_PATH" | head -1 | cut -d: -f1)

if [ -z "$STEP5_LINE" ]; then
  fail_msg "could not find '5. **Set up worktrees**' anchor in $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

# Read a window of ~30 lines after the anchor (the step 5 body).
WINDOW_END=$((STEP5_LINE + 30))
STEP5_WINDOW=$(sed -n "${STEP5_LINE},${WINDOW_END}p" "$SKILL_PATH")

# Assertion 1: The literal string `setup-worktree.sh` appears in the window.
inc
if echo "$STEP5_WINDOW" | grep -qF 'setup-worktree.sh'; then
  pass_msg "step 5 mentions setup-worktree.sh"
else
  fail_msg "step 5 window (lines $STEP5_LINE-$WINDOW_END) does not mention 'setup-worktree.sh'"
fi

# Assertion 2: Documented branch shape — feature/<slug> or feature/<...>.
inc
if echo "$STEP5_WINDOW" | grep -qE 'feature/<[^>]+>'; then
  pass_msg "step 5 documents branch shape feature/<slug>"
else
  fail_msg "step 5 window does not document branch shape (expected feature/<slug> or feature/<something>)"
fi

# Assertion 3: A worked two-argument example invoking setup-worktree.sh with
# both a feature/<slug> branch and an integer issue number.
inc
if echo "$STEP5_WINDOW" | grep -qE 'setup-worktree\.sh[[:space:]]+(--base[[:space:]]+[^[:space:]]+[[:space:]]+)?feature/[a-z0-9-]+[[:space:]]+[0-9]+'; then
  pass_msg "step 5 shows worked two-argument example (feature/<slug> <integer>)"
else
  fail_msg "step 5 window does not contain a worked example like 'setup-worktree.sh feature/gmail-ci-filter 81'"
fi

# Assertion 4: An explicit "Do NOT invoke with only the issue number" callout.
inc
if echo "$STEP5_WINDOW" | grep -qiE '[Dd]o NOT invoke.*only the issue number|[Dd]o not invoke.*only the issue'; then
  pass_msg "step 5 contains 'Do NOT invoke with only the issue number' callout"
else
  fail_msg "step 5 window lacks an explicit 'Do NOT invoke with only the issue number' callout"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
