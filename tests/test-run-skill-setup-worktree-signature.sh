#!/bin/bash
# Asserts that the setup-worktree.sh execution call site documents the full
# invocation signature: both positional args (branch-name + issue-number), a
# worked example, a cross-link to the "Branch and worktree naming convention"
# block (heading-text reference, never a hard-coded line number), and a
# "Do NOT invoke with only the issue number" callout.
#
# Introduced by issue #350 (parallel to fullsend Task 3).
#
# #763 repoint: the run→status rename moved ALL dispatch/worktree-setup wiring
# out of the (now read-only) /pipeline:status skill into skills/fullsend/SKILL.md.
# So the execution call site is now fullsend's Step 5 "Set up worktrees" block.
# The old Site A "propose setting up worktrees" proposal-prose narration was
# DELETED — autonomous fullsend sets up worktrees wave-by-wave directly; it does
# not narrate a proposal first (status, the read-only successor, proposes
# nothing). Only the execution-block assertions remain, scoped to fullsend.
# The "Branch and worktree naming convention" heading the call site cross-links
# to now lives in skills/status/SKILL.md (the canonical convention home).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_PATH="$SCRIPT_DIR/../skills/fullsend/SKILL.md"
CONVENTION_PATH="$SCRIPT_DIR/../skills/status/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_PATH" ]; then
  fail_msg "fullsend SKILL.md not found at $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

# -----------------------------------------------------------------------------
# Locate the execution call site — fullsend's Step 5 "Set up worktrees" block.
# Anchor on the numbered step heading and window forward to the next numbered
# step (Step 6 "Execute").
# -----------------------------------------------------------------------------
SITE_LINE=$(grep -nE '^5\. \*\*Set up worktrees\*\*' "$SKILL_PATH" | head -1 | cut -d: -f1)

if [ -z "$SITE_LINE" ]; then
  fail_msg "could not find execution call site anchor ('5. **Set up worktrees**') in $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

SITE_END=$((SITE_LINE + 30))
SITE_WINDOW=$(sed -n "${SITE_LINE},${SITE_END}p" "$SKILL_PATH")

# Assertion 1: mentions setup-worktree.sh literally.
inc
if echo "$SITE_WINDOW" | grep -qF 'setup-worktree.sh'; then
  pass_msg "execution site mentions setup-worktree.sh"
else
  fail_msg "execution site window (lines $SITE_LINE-$SITE_END) does not mention 'setup-worktree.sh'"
fi

# Assertion 2: documents branch shape feature/<slug>.
inc
if echo "$SITE_WINDOW" | grep -qE 'feature/<[^>]+>'; then
  pass_msg "execution site documents branch shape feature/<slug>"
else
  fail_msg "execution site window does not document branch shape (expected feature/<slug>)"
fi

# Assertion 3: shows worked two-argument example with both feature/<slug> and
# an integer issue number.
inc
if echo "$SITE_WINDOW" | grep -qE 'setup-worktree\.sh[[:space:]]+(--base[[:space:]]+[^[:space:]]+[[:space:]]+)?feature/[a-z0-9-]+[[:space:]]+[0-9]+'; then
  pass_msg "execution site shows worked two-argument example (feature/<slug> <integer>)"
else
  fail_msg "execution site window does not contain a worked example like 'setup-worktree.sh feature/gmail-ci-filter 81'"
fi

# Assertion 4: cross-links to the branch-naming convention block.
inc
if echo "$SITE_WINDOW" | grep -qiE 'Branch and worktree naming convention|branch[- ]naming convention'; then
  pass_msg "execution site cross-links to the Branch and worktree naming convention block"
else
  fail_msg "execution site window does not cross-link to the 'Branch and worktree naming convention' block"
fi

# Assertion 5: explicit "Do NOT invoke with only the issue number" callout —
# the most important defense at the actual invocation site.
inc
if echo "$SITE_WINDOW" | grep -qiE '[Dd]o NOT invoke.*only the issue number|[Dd]o not invoke.*only the issue'; then
  pass_msg "execution site contains 'Do NOT invoke with only the issue number' callout"
else
  fail_msg "execution site window lacks an explicit 'Do NOT invoke with only the issue number' callout"
fi

# -----------------------------------------------------------------------------
# Cross-cutting assertion: the "Branch and worktree naming convention" heading
# that the call site points at must actually exist as a heading. After the
# run→status rename the canonical convention home is skills/status/SKILL.md.
# -----------------------------------------------------------------------------
inc
if grep -qE '^#{1,4}[[:space:]]+Branch and worktree naming convention' "$CONVENTION_PATH"; then
  pass_msg "'Branch and worktree naming convention' heading exists in skills/status/SKILL.md"
else
  fail_msg "convention heading missing from $CONVENTION_PATH (cross-refs would be dead)"
fi

# -----------------------------------------------------------------------------
# Cross-cutting assertion: cross-references to the convention block must NOT
# bake in a hard-coded line number — those drift the moment anyone adds prose
# above the heading. Heading-text references are durable; "(line NNN)" is not.
# -----------------------------------------------------------------------------
inc
if grep -nE '\(line[[:space:]]+[0-9]+\)' "$SKILL_PATH" | grep -qiE 'convention|branch'; then
  fail_msg "found hard-coded '(line N)' annotation near a convention/branch cross-ref in $SKILL_PATH"
else
  pass_msg "no hard-coded '(line N)' annotations in convention/branch cross-refs"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
