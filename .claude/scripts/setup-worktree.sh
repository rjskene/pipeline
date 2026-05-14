#!/bin/bash
set -euo pipefail

# Source project config
source "$(cd "$(dirname "$0")/../.." && pwd)/pipeline.config"

# Atomic worktree setup for the pipeline.
# Usage: bash .claude/scripts/setup-worktree.sh [--base <base-branch>] <branch-name> [issue-number]
# Example: bash .claude/scripts/setup-worktree.sh --base remove-user-switching feature/rating-system 5

# Parse optional --base flag
BASE_BRANCH=""
if [ "${1:-}" = "--base" ]; then
  BASE_BRANCH="$2"
  shift 2
fi

if [ $# -lt 1 ]; then
  echo "Usage: bash .claude/scripts/setup-worktree.sh [--base <base-branch>] <branch-name> [issue-number]"
  echo "Example: bash .claude/scripts/setup-worktree.sh --base remove-user-switching feature/rating-system 5"
  exit 1
fi

BRANCH="$1"
ISSUE_NUM="${2:-}"
SUFFIX="${BRANCH#feature/}"
MAIN_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKTREE_DIR="$MAIN_REPO/.claude/worktrees"
if [ -n "$ISSUE_NUM" ]; then
  WORKTREE_PATH="$WORKTREE_DIR/${PIPELINE_WORKTREE_PREFIX}-${ISSUE_NUM}-${SUFFIX}"
else
  WORKTREE_PATH="$WORKTREE_DIR/${PIPELINE_WORKTREE_PREFIX}-${SUFFIX}"
fi

echo "=== Worktree Setup: $BRANCH ==="
echo "  Repo:     $MAIN_REPO"
echo "  Worktree: $WORKTREE_PATH"
echo ""

# Step 1: Create worktree (skip if exists)
if git -C "$MAIN_REPO" worktree list | grep -q "$WORKTREE_PATH"; then
  echo "[1/5] Worktree already exists — skipping creation"
else
  echo "[1/5] Creating worktree..."
  if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$MAIN_REPO" worktree add "$WORKTREE_PATH" "$BRANCH"
  else
    git -C "$MAIN_REPO" worktree add "$WORKTREE_PATH" -b "$BRANCH"
  fi
fi

# Step 2: Sync untracked .claude/ files (settings.local.json, untracked hooks, .env files, venvs)
echo "[2/5] Syncing untracked files (.claude/, .env)..."
mkdir -p "$WORKTREE_PATH/.claude/hooks"
if [ -f "$MAIN_REPO/.claude/settings.local.json" ]; then
  cp "$MAIN_REPO/.claude/settings.local.json" "$WORKTREE_PATH/.claude/settings.local.json"
fi
# Sync .env files
for envfile in $PIPELINE_SYNC_ENVS; do
  if [ -f "$MAIN_REPO/$envfile" ]; then
    mkdir -p "$WORKTREE_PATH/$(dirname "$envfile")"
    cp "$MAIN_REPO/$envfile" "$WORKTREE_PATH/$envfile"
    echo "  Copied $envfile"
  fi
done
# Symlink venvs from main repo (avoids duplicating large venvs)
for venvdir in $PIPELINE_SYNC_VENVS; do
  if [ -d "$MAIN_REPO/$venvdir" ]; then
    mkdir -p "$WORKTREE_PATH/$(dirname "$venvdir")"
    ln -sfn "$MAIN_REPO/$venvdir" "$WORKTREE_PATH/$venvdir"
    echo "  Symlinked $venvdir"
  fi
done

for hook in "$MAIN_REPO/.claude/hooks/"*; do
  [ -f "$hook" ] || continue
  fname="$(basename "$hook")"
  if ! git -C "$MAIN_REPO" ls-files --error-unmatch ".claude/hooks/$fname" >/dev/null 2>&1; then
    cp "$hook" "$WORKTREE_PATH/.claude/hooks/$fname"
    echo "  Copied untracked hook: $fname"
  fi
done

# Step 3: Install dependencies
echo "[3/5] Installing dependencies..."
(cd "$WORKTREE_PATH" && eval "$PIPELINE_INSTALL_CMD")

# Step 4: Seed database (if configured)
if [ -n "$PIPELINE_SEED_CMD" ]; then
  echo "[4/5] Seeding database..."
  (cd "$WORKTREE_PATH" && eval "$PIPELINE_SEED_CMD")
else
  echo "[4/5] No seed command configured — skipping"
fi

# Step 5: Determine base branch (if not explicitly provided) and write metadata file
if [ -z "$BASE_BRANCH" ]; then
  CURRENT_BRANCH=$(git -C "$MAIN_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  if [ "$CURRENT_BRANCH" = "HEAD" ] || [ "$CURRENT_BRANCH" = "main" ]; then
    BASE_BRANCH="$PIPELINE_BASE_BRANCH"
    echo "  Current branch is '$CURRENT_BRANCH' — defaulting base to PIPELINE_BASE_BRANCH='$BASE_BRANCH'."
  else
    BASE_BRANCH="$CURRENT_BRANCH"
    echo "  No --base provided — defaulting base to current branch: '$BASE_BRANCH'."
  fi
fi
# Verify base branch exists on remote; push if needed
if ! git -C "$MAIN_REPO" ls-remote --heads origin "$BASE_BRANCH" | grep -q "$BASE_BRANCH"; then
  echo "[5/5] Base branch '$BASE_BRANCH' not on remote — pushing..."
  git -C "$MAIN_REPO" push -u origin "$BASE_BRANCH"
fi
mkdir -p "$WORKTREE_PATH/.claude"
echo "$BASE_BRANCH" > "$WORKTREE_PATH/.claude/base-branch"
echo "[5/5] Wrote base branch metadata: $BASE_BRANCH"

echo ""
echo "=== Setup complete ==="
echo ""
echo "  Worktree:    $WORKTREE_PATH"
echo "  Base branch: $BASE_BRANCH"
echo "  Execute issue:  claude \"/execute-issue-plan <N>\""
