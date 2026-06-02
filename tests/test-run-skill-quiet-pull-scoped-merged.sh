#!/bin/bash
# Tests for skills/run/SKILL.md step 0 / step 1 (issue #341):
#   - step 0 git pull must be `--quiet` so the orchestrator does not pull
#     the fast-forward file list into context.
#   - step 1 merged-PR lookup must be scoped per active-worktree branch
#     instead of issuing a single site-wide `gh pr list --state merged`
#     call.
# The run skill is markdown executed by the orchestrator, so the test
# asserts structural anchors in the SKILL.md prose itself (matching the
# style of sibling tests/test-run-skill-grouped-status.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/status/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 (pattern: $2)"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

want_present() {
  local name="$1" pat="$2"
  inc
  if grep -qE -- "$pat" "$SKILL"; then
    pass_msg "$name"
  else
    fail_msg "$name" "$pat"
  fi
}

want_absent() {
  local name="$1" pat="$2"
  inc
  if grep -qE -- "$pat" "$SKILL"; then
    fail_msg "$name (unexpected pattern present)" "$pat"
  else
    pass_msg "$name"
  fi
}

# 1. step 0 quiet git pull
want_present "git pull is quiet in step 0" 'git pull --quiet origin "\$\{?EXPECTED_BASE\}?"'

# 2. legacy unscoped merged-PR lookup is gone from step 1
want_absent "unscoped merged-PR lookup removed from step 1" 'gh pr list --repo \$PIPELINE_REPO --state merged --json headRefName,number --jq'

# 3. step 1 iterates active-worktree branches
want_present "step 1 iterates worktree branches" 'git worktree list --porcelain'

# 4. step 1 looks up merged PRs per branch via --head
want_present "step 1 looks up merged PRs per branch" 'gh pr list --repo \$PIPELINE_REPO --head .* --state merged'

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
