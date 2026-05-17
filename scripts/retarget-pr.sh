#!/bin/bash
set -euo pipefail

# Run from the consumer repo root (so `$(pwd)/pipeline.config` resolves), or
# export PIPELINE_PROJECT_ROOT to override the lookup directory.
source "${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config"

# Retarget a PR's base branch with verify-retry-fail pattern.
# Tries gh pr edit first, falls back to REST API if that fails.
#
# Usage: bash ${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh <pr_number> <target_base_branch>
# Exit codes: 0 = success (already correct or retargeted), 1 = failure

if [ $# -lt 2 ]; then
  echo "Usage: bash \${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh <pr_number> <target_base_branch>"
  exit 1
fi

PR="$1"
TARGET="$2"

# --- Step 1: Read current base branch ---
CURRENT_BASE=$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json baseRefName --jq '.baseRefName')

if [ "$CURRENT_BASE" = "$TARGET" ]; then
  echo "[retarget] PR #$PR already targets $TARGET"
  exit 0
fi

echo "[retarget] PR #$PR currently targets $CURRENT_BASE, retargeting to $TARGET"

# --- Step 2: Attempt 1 — gh pr edit ---
echo "[retarget] Attempt 1: gh pr edit --base $TARGET"
if gh pr edit "$PR" --repo "$PIPELINE_REPO" --base "$TARGET" 2>&1; then
  # Verify
  VERIFY_BASE=$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json baseRefName --jq '.baseRefName')
  if [ "$VERIFY_BASE" = "$TARGET" ]; then
    echo "[retarget] PR #$PR retargeted to $TARGET (gh pr edit)"
    exit 0
  fi
  echo "[retarget] gh pr edit reported success but verification failed (base is $VERIFY_BASE)"
else
  echo "[retarget] gh pr edit failed, trying REST API fallback"
fi

# --- Step 3: Attempt 2 — REST API fallback ---
echo "[retarget] Attempt 2: REST API PATCH"
if gh api "repos/$PIPELINE_REPO/pulls/$PR" -X PATCH -f base="$TARGET" 2>&1; then
  # Verify
  VERIFY_BASE=$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json baseRefName --jq '.baseRefName')
  if [ "$VERIFY_BASE" = "$TARGET" ]; then
    echo "[retarget] PR #$PR retargeted to $TARGET (REST API fallback)"
    exit 0
  fi
  echo "[retarget] REST API reported success but verification failed (base is $VERIFY_BASE)"
else
  echo "[retarget] REST API fallback also failed"
fi

# --- Step 4: Both methods failed ---
echo "ERROR: Failed to retarget PR #$PR to $TARGET after both methods" >&2
exit 1
