#!/bin/bash
# Asserts that BOTH setup-worktree.sh call sites in skills/run/SKILL.md
# document the full invocation signature: both positional args
# (branch-name + issue-number), a worked example, a cross-link to the
# "Branch and worktree naming convention" block (heading-text reference,
# never a hard-coded line number), and a "Do NOT invoke with only the
# issue number" callout.
#
# Site A: the proposal-prose call site under the ladder (around line 435)
#         where the orchestrator proposes setting up worktrees.
# Site B: the execution-block call site under the "For execution
#         (plan-approved -> worktree setup)" block (around line 556)
#         where the script is actually invoked.
#
# Introduced by issue #350 (parallel to fullsend Task 3).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_PATH="$SCRIPT_DIR/../skills/run/SKILL.md"

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

# -----------------------------------------------------------------------------
# Locate Site A — the proposal-prose call site.
# Anchor on the literal phrase "propose setting up worktrees" which is the
# under-specified prose currently at ~line 435.
# -----------------------------------------------------------------------------
SITE_A_LINE=$(grep -nF 'propose setting up worktrees' "$SKILL_PATH" | head -1 | cut -d: -f1)

if [ -z "$SITE_A_LINE" ]; then
  fail_msg "could not find Site A anchor ('propose setting up worktrees') in $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

# Window forward ~25 lines from the anchor.
SITE_A_END=$((SITE_A_LINE + 25))
SITE_A_WINDOW=$(sed -n "${SITE_A_LINE},${SITE_A_END}p" "$SKILL_PATH")

# Site A assertion 1: mentions setup-worktree.sh literally.
inc
if echo "$SITE_A_WINDOW" | grep -qF 'setup-worktree.sh'; then
  pass_msg "Site A mentions setup-worktree.sh"
else
  fail_msg "Site A window (lines $SITE_A_LINE-$SITE_A_END) does not mention 'setup-worktree.sh'"
fi

# Site A assertion 2: documents branch shape feature/<slug>.
inc
if echo "$SITE_A_WINDOW" | grep -qE 'feature/<[^>]+>'; then
  pass_msg "Site A documents branch shape feature/<slug>"
else
  fail_msg "Site A window does not document branch shape (expected feature/<slug> or feature/<something>)"
fi

# Site A assertion 3: shows worked two-argument example with both
# feature/<slug> and an integer issue number.
inc
if echo "$SITE_A_WINDOW" | grep -qE 'setup-worktree\.sh[[:space:]]+(--base[[:space:]]+[^[:space:]]+[[:space:]]+)?feature/[a-z0-9-]+[[:space:]]+[0-9]+'; then
  pass_msg "Site A shows worked two-argument example (feature/<slug> <integer>)"
else
  fail_msg "Site A window does not contain a worked example like 'setup-worktree.sh feature/gmail-ci-filter 81'"
fi

# Site A assertion 4: cross-links to the branch-naming convention block.
inc
if echo "$SITE_A_WINDOW" | grep -qiE 'Branch and worktree naming convention|branch[- ]naming convention'; then
  pass_msg "Site A cross-links to the Branch and worktree naming convention block"
else
  fail_msg "Site A window does not cross-link to the 'Branch and worktree naming convention' block"
fi

# -----------------------------------------------------------------------------
# Locate Site B — the execution-block call site.
# Anchor on the literal phrase "Run the setup script with" which is the
# leading prose of the numbered step (~line 554) that introduces the
# invocation code block.
# -----------------------------------------------------------------------------
SITE_B_LINE=$(grep -nF 'Run the setup script with' "$SKILL_PATH" | head -1 | cut -d: -f1)

if [ -z "$SITE_B_LINE" ]; then
  fail_msg "could not find Site B anchor ('Run the setup script with') in $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

SITE_B_END=$((SITE_B_LINE + 25))
SITE_B_WINDOW=$(sed -n "${SITE_B_LINE},${SITE_B_END}p" "$SKILL_PATH")

# Site B assertion 1: mentions setup-worktree.sh literally.
inc
if echo "$SITE_B_WINDOW" | grep -qF 'setup-worktree.sh'; then
  pass_msg "Site B mentions setup-worktree.sh"
else
  fail_msg "Site B window (lines $SITE_B_LINE-$SITE_B_END) does not mention 'setup-worktree.sh'"
fi

# Site B assertion 2: documents branch shape feature/<slug>.
inc
if echo "$SITE_B_WINDOW" | grep -qE 'feature/<[^>]+>'; then
  pass_msg "Site B documents branch shape feature/<slug>"
else
  fail_msg "Site B window does not document branch shape (expected feature/<slug> or feature/<something>)"
fi

# Site B assertion 3: shows worked two-argument example with both
# feature/<slug> and an integer issue number.
inc
if echo "$SITE_B_WINDOW" | grep -qE 'setup-worktree\.sh[[:space:]]+(--base[[:space:]]+[^[:space:]]+[[:space:]]+)?feature/[a-z0-9-]+[[:space:]]+[0-9]+'; then
  pass_msg "Site B shows worked two-argument example (feature/<slug> <integer>)"
else
  fail_msg "Site B window does not contain a worked example like 'setup-worktree.sh feature/gmail-ci-filter 81'"
fi

# Site B assertion 4: cross-links to the branch-naming convention block.
inc
if echo "$SITE_B_WINDOW" | grep -qiE 'Branch and worktree naming convention|branch[- ]naming convention'; then
  pass_msg "Site B cross-links to the Branch and worktree naming convention block"
else
  fail_msg "Site B window does not cross-link to the 'Branch and worktree naming convention' block"
fi

# Site B assertion 5: explicit "Do NOT invoke with only the issue number"
# callout — this is the most important defense at the actual invocation site.
inc
if echo "$SITE_B_WINDOW" | grep -qiE '[Dd]o NOT invoke.*only the issue number|[Dd]o not invoke.*only the issue'; then
  pass_msg "Site B contains 'Do NOT invoke with only the issue number' callout"
else
  fail_msg "Site B window lacks an explicit 'Do NOT invoke with only the issue number' callout"
fi

# -----------------------------------------------------------------------------
# Cross-cutting assertion: the "Branch and worktree naming convention" heading
# that both Site A and Site B point at must actually exist as a heading in
# SKILL.md. If anyone renames or removes the block, this test fails loudly
# rather than letting Site A/B silently point at a dead target.
# -----------------------------------------------------------------------------
inc
if grep -qE '^#{1,4}[[:space:]]+Branch and worktree naming convention' "$SKILL_PATH"; then
  pass_msg "'Branch and worktree naming convention' heading exists in SKILL.md"
else
  fail_msg "convention heading missing from $SKILL_PATH (Site A and Site B cross-refs would be dead)"
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
