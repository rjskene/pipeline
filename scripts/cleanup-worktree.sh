#!/bin/bash
set -euo pipefail

# Run from the consumer repo root (so `$(pwd)/pipeline.config` resolves), or
# export PIPELINE_PROJECT_ROOT to override the lookup directory.
source "${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config"

# Logging gate helper (pipeline_logging_enabled).
source "$(dirname "${BASH_SOURCE[0]}")/_logging.sh"

# Clean up a worktree after its PR has been merged/closed.
# Verifies PR is closed, closes the issue, consolidates logs,
# removes worktree, and deletes the branch.
#
# Usage: bash ${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-worktree.sh <issue-number> [--force]
#   --force  Skip the PR-closed check (for manual cleanup of abandoned worktrees)

if [ $# -lt 1 ]; then
  echo "Usage: bash \${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-worktree.sh <issue-number> [--force]"
  exit 1
fi

ISSUE_NUM="$1"
FORCE="${2:-}"
MAIN_REPO="${PIPELINE_PROJECT_ROOT:-$(pwd)}"

# --- Discover worktree path from git worktree list ---
WORKTREE_PATH=""
while IFS= read -r line; do
  wt_path="$(echo "$line" | awk '{print $1}')"
  if [[ "$(basename "$wt_path")" == ${PIPELINE_WORKTREE_PREFIX}-${ISSUE_NUM}-* ]]; then
    WORKTREE_PATH="$wt_path"
    break
  fi
done < <(git -C "$MAIN_REPO" worktree list)

if [ -z "$WORKTREE_PATH" ]; then
  echo "ERROR: No worktree found for issue #${ISSUE_NUM}"
  echo "Active worktrees:"
  git -C "$MAIN_REPO" worktree list
  exit 1
fi

BRANCH="$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

# Discover the merged/closed PR number for this branch (used for checkpoint-tag annotation)
PR_NUM="$(gh pr list --repo "$PIPELINE_REPO" --head "$BRANCH" --state all \
  --json number --jq '.[0].number // empty' 2>/dev/null || echo "")"
if [ -z "$PR_NUM" ]; then
  PR_NUM="none"
fi

echo "=== Worktree Cleanup: Issue #${ISSUE_NUM} ==="
echo "  Worktree: $WORKTREE_PATH"
echo "  Branch:   $BRANCH"
echo "  PR:       ${PR_NUM}"
echo ""

# --- Step 1: Verify PR is merged or closed ---
if [ "$FORCE" != "--force" ]; then
  echo "[1/6] Checking PR status..."
  PR_STATE="$(gh pr list --repo "$PIPELINE_REPO" --head "$BRANCH" --state all \
    --json state --jq '.[0].state // empty' 2>/dev/null || echo "")"

  if [ -z "$PR_STATE" ]; then
    echo "  WARNING: No PR found for branch '$BRANCH'"
    echo "  Use --force to clean up anyway."
    exit 1
  elif [ "$PR_STATE" = "OPEN" ]; then
    echo "  ERROR: PR for branch '$BRANCH' is still OPEN."
    echo "  Merge or close the PR first, or use --force."
    exit 1
  else
    echo "  PR state: $PR_STATE — OK"
  fi
else
  echo "[1/6] Skipping PR check (--force)"
fi

# --- Step 2: Close the GitHub issue ---
echo "[2/6] Closing issue #${ISSUE_NUM}..."
ISSUE_STATE="$(gh issue view "$ISSUE_NUM" --repo "$PIPELINE_REPO" --json state --jq '.state' 2>/dev/null || echo "")"
if [ "$ISSUE_STATE" = "OPEN" ]; then
  gh issue close "$ISSUE_NUM" --repo "$PIPELINE_REPO" --reason completed
  gh issue edit "$ISSUE_NUM" --repo "$PIPELINE_REPO" --add-label "merged" --remove-label "pr-open" 2>/dev/null || true
  echo "  Issue #${ISSUE_NUM} closed"
elif [ "$ISSUE_STATE" = "CLOSED" ]; then
  echo "  Issue #${ISSUE_NUM} already closed"
else
  echo "  WARNING: Could not determine issue state (got: '$ISSUE_STATE')"
fi

# --- Step 3: Consolidate tool-use logs ---
echo "[3/5] Consolidating tool-use logs..."
if pipeline_logging_enabled; then
  WORKTREE_LOG="$WORKTREE_PATH/.claude/logs/tool-use.log"
  ROOT_LOG_DIR="$MAIN_REPO/.claude/logs"
  mkdir -p "$ROOT_LOG_DIR"
  if [ -f "$WORKTREE_LOG" ]; then
    cp "$WORKTREE_LOG" "$ROOT_LOG_DIR/tool-use-issue-${ISSUE_NUM}.log"
    echo "  Copied to $ROOT_LOG_DIR/tool-use-issue-${ISSUE_NUM}.log"
  else
    echo "  No tool-use log found in worktree"
  fi
else
  echo "  Skipping tool-use log copy (PIPELINE_LOGS_ENABLED=false)"
fi

# --- Step 4: Remove the git worktree ---
echo "[4/5] Removing git worktree..."
git -C "$MAIN_REPO" worktree remove "$WORKTREE_PATH" --force 2>/dev/null \
  || { rm -rf "$WORKTREE_PATH" && git -C "$MAIN_REPO" worktree prune && echo "  Forced directory removal + prune"; }
echo "  Worktree removed"

# --- Step 5: Delete the remote branch ---
echo "[5/5] Cleaning up branch '$BRANCH'..."
if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ]; then
  git -C "$MAIN_REPO" push origin --delete "$BRANCH" 2>/dev/null && echo "  Remote branch deleted" || echo "  Remote branch already deleted or not found"
  git -C "$MAIN_REPO" branch -D "$BRANCH" 2>/dev/null && echo "  Local branch deleted" || echo "  Local branch already deleted"
else
  echo "  Skipping branch cleanup (branch: '$BRANCH')"
fi

echo ""
echo "=== Cleanup complete for issue #${ISSUE_NUM} ==="

# Machine-readable summary line — parsed by the pipeline skill orchestrator
# to batch a single checkpoint tag per full-send run.
echo "CLEANUP-SUMMARY: issue=${ISSUE_NUM} pr=${PR_NUM} branch=${BRANCH}"
