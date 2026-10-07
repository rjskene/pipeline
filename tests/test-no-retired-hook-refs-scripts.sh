#!/bin/bash
set -uo pipefail

# Issue #1418 retires two PreToolUse guard hooks. The deny rail is now the
# session's own permission mode (the auto-mode classifier plus the #1421
# PermissionRequest bridge) together with enforce-comment-trust.py.
#
# This guard holds the SCRIPT layer to that: no script comment may justify its
# behaviour by naming a hook that no longer exists, because such a comment
# sends the next reader looking for a file that is not there. The surviving
# rules themselves are unchanged — only their stated rationale moves.
#
# Scope is deliberately the five scripts whose comments cited the retired
# hooks. Widening the file list is a one-line follow-up; other layers (docs,
# skills, the plugin manifest) are held by their own guards.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

SCRIPTS=(
  scripts/calibration-run.sh
  scripts/setup-worktree.sh
  scripts/fetch-issue-attachments.sh
  scripts/derive-pr-title.sh
  scripts/exact-match-guard-sweep.sh
)

# The retired hook basenames, assembled from fragments so this guard's own
# SOURCE never carries the token it forbids (the convention already used by
# tests/test_command_mask.py for /dev/null).
RETIRED=(
  "restrict""_paths"
  "block""_deletions"
)

for rel in "${SCRIPTS[@]}"; do
  f="$ROOT/$rel"
  inc
  if [ -f "$f" ]; then
    pass_msg "$rel exists"
  else
    fail_msg "$rel not found (expected a surviving script)"
    continue
  fi
  for tok in "${RETIRED[@]}"; do
    inc
    if grep -Fq "$tok" "$f"; then
      hits="$(grep -Fn "$tok" "$f" | head -3 | tr '\n' ' ')"
      fail_msg "$rel still names the retired hook '$tok': $hits"
    else
      pass_msg "$rel does not name the retired hook '$tok'"
    fi
  done
done

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
