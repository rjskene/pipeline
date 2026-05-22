#!/bin/bash
# Asserts that BOTH setup-worktree.sh call sites in skills/run/SKILL.md
# document the full invocation signature: both positional args
# (branch-name + issue-number), a worked example, a cross-link to the
# "Branch and worktree naming convention" block (line ~137), and a
# "Do NOT invoke with only the issue number" callout.
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

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
