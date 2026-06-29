#!/bin/bash
set -euo pipefail

# Run from the consumer repo root (so `$(pwd)/pipeline.config` resolves), or
# export PIPELINE_PROJECT_ROOT to override the lookup directory.
source "${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config"

# Atomic worktree setup for the pipeline.
# Usage: bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh [--base <base-branch>] <branch-name> [issue-number]
# Example: bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh --base remove-user-switching feature/rating-system 5

# Parse optional --base flag
BASE_BRANCH=""
if [ "${1:-}" = "--base" ]; then
  BASE_BRANCH="$2"
  shift 2
fi

if [ $# -lt 1 ]; then
  echo "Usage: bash \${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh [--base <base-branch>] <branch-name> [issue-number]"
  echo "Example: bash \${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh --base remove-user-switching feature/rating-system 5"
  exit 1
fi

BRANCH="$1"
ISSUE_NUM="${2:-}"

# Reject branch names without an allowed Conventional Commits prefix.
# Without this guard, a bare integer like `setup-worktree.sh 81` silently
# creates a worktree on a branch literally named `81`, which breaks every
# downstream pipeline stage (issue #350).
case "$BRANCH" in
  feature/*|fix/*|chore/*|docs/*|refactor/*|test/*|perf/*|ci/*|build/*|revert/*) ;;
  *)
    echo "ERROR: branch name must start with one of feature/, fix/, chore/, docs/, refactor/, test/, perf/, ci/, build/, revert/ — got: $BRANCH" >&2
    echo "Usage: $0 [--base <base>] <branch-name> <issue-number>" >&2
    echo "Example: $0 feature/gmail-ci-filter 81" >&2
    exit 2
    ;;
esac

# Strip everything up through the first slash so any allowed Conventional
# Commits prefix (feature/, fix/, chore/, ...) collapses to its trailing slug.
# Without this, `fix/foo` would leak the `fix/` prefix into the worktree dir
# name (`wt-81-fix/foo`) and break downstream `find_worktree` matching (#350).
SUFFIX="${BRANCH#*/}"
# Post-strip validation: the slug must be a non-empty, single segment so the
# worktree directory always has the shape `wt-<N>-<slug>` with no embedded
# slashes. Empty (`feature/`) and multi-segment (`feature/foo/bar`) inputs
# are bad-arg-shape errors in the same family as the prefix check above; use
# the same exit code 2 so callers can treat them uniformly.
if [ -z "$SUFFIX" ]; then
  echo "ERROR: branch name must have a non-empty slug after the prefix — got: $BRANCH" >&2
  echo "Usage: $0 [--base <base>] <branch-name> <issue-number>" >&2
  echo "Example: $0 feature/gmail-ci-filter 81" >&2
  exit 2
fi
case "$SUFFIX" in
  */*)
    echo "ERROR: branch slug must be a single segment, no embedded '/' — got: $BRANCH" >&2
    echo "Usage: $0 [--base <base>] <branch-name> <issue-number>" >&2
    echo "Example: $0 feature/gmail-ci-filter 81" >&2
    exit 2
    ;;
esac
MAIN_REPO="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
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

# Resolve the orchestrator's current local branch — used to decide whether
# --base ACTUATES (fetch + cut from origin/<base>) or stays metadata-only.
CURRENT_LOCAL_BRANCH=$(git -C "$MAIN_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

# Next-branch routing actuation (#1128). When --base names a branch OTHER than
# the orchestrator's current local branch (the next-branch case), the worktree
# must be cut from origin/<base>'s tip — NOT MAIN_REPO's local HEAD — so
# next-labelled work actually lands ON the next-branch. If origin/<base> does
# not exist anywhere, auto-create it from PIPELINE_BASE_BRANCH.
#
# The DEFAULT path (no --base, or --base == current local branch) is UNCHANGED:
# it cuts from LOCAL HEAD and relies on the inter-wave pull (#626). The
# fetch/cut below is gated strictly on --base naming a non-current branch.
ACTUATE_BASE=0
if [ -n "$BASE_BRANCH" ] && [ "$BASE_BRANCH" != "$CURRENT_LOCAL_BRANCH" ]; then
  ACTUATE_BASE=1
fi

# Step 1: Create worktree (skip if exists)
if git -C "$MAIN_REPO" worktree list | grep -q "$WORKTREE_PATH"; then
  echo "[1/6] Worktree already exists — skipping creation"
elif git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  # The feature branch already exists locally — reattach it as-is (resumption).
  echo "[1/6] Creating worktree (existing branch)..."
  git -C "$MAIN_REPO" worktree add "$WORKTREE_PATH" "$BRANCH"
elif [ "$ACTUATE_BASE" = "1" ]; then
  # Next-branch routing: fetch origin/<base> and cut the worktree from its tip.
  echo "[1/6] Creating worktree off origin/$BASE_BRANCH (--base actuation)..."
  if git -C "$MAIN_REPO" fetch --quiet origin "$BASE_BRANCH" 2>/dev/null \
     && git -C "$MAIN_REPO" show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
    git -C "$MAIN_REPO" worktree add "$WORKTREE_PATH" -b "$BRANCH" "origin/$BASE_BRANCH"
  else
    # origin/<base> does not exist anywhere — auto-create it from
    # PIPELINE_BASE_BRANCH (the active dev trunk), push it, then cut from it.
    echo "  origin/$BASE_BRANCH absent — auto-creating from PIPELINE_BASE_BRANCH='$PIPELINE_BASE_BRANCH'..."
    git -C "$MAIN_REPO" fetch --quiet origin "$PIPELINE_BASE_BRANCH"
    git -C "$MAIN_REPO" branch -f "$BASE_BRANCH" "origin/$PIPELINE_BASE_BRANCH"
    git -C "$MAIN_REPO" push -u origin "$BASE_BRANCH"
    git -C "$MAIN_REPO" worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_BRANCH"
  fi
else
  echo "[1/6] Creating worktree..."
  # Branches off MAIN_REPO's LOCAL HEAD -- NOT origin/<base>. $BASE_BRANCH below
  # is metadata/remote-existence only. Wave-running callers (fullsend) MUST
  # `git pull --ff-only origin <base>` on MAIN_REPO between waves so a later
  # wave's worktree inherits prior waves' merged-on-remote work (#626).
  git -C "$MAIN_REPO" worktree add "$WORKTREE_PATH" -b "$BRANCH"
fi

# Step 2: Sync untracked .claude/ files (settings.local.json, untracked hooks, .env files, venvs)
echo "[2/6] Syncing untracked files (.claude/, .env)..."
mkdir -p "$WORKTREE_PATH/.claude/hooks"
if [ -f "$MAIN_REPO/.claude/settings.local.json" ]; then
  cp "$MAIN_REPO/.claude/settings.local.json" "$WORKTREE_PATH/.claude/settings.local.json"
fi
# Copy host-specific pipeline.config so the worktree-local `source ./pipeline.config`
# in execute-issue-plan / evaluate-issue-pr Boot resolves PIPELINE_* vars. The main
# checkout's copy is unreadable from inside a worktree (restrict_paths.py boundary).
# gitignored + host-specific, so this is a runtime copy, not tracked (#529).
if [ -f "$MAIN_REPO/pipeline.config" ]; then
  cp "$MAIN_REPO/pipeline.config" "$WORKTREE_PATH/pipeline.config"
  echo "  Copied pipeline.config"
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

# Step 3: Mirror per-issue scratch attachments into the worktree
if [ -n "${ISSUE_NUM:-}" ] && [ -d "$MAIN_REPO/.claude/scratch/issue-${ISSUE_NUM}" ]; then
  echo "[3/6] Mirroring .claude/scratch/issue-${ISSUE_NUM}/ into worktree..."
  mkdir -p "$WORKTREE_PATH/.claude/scratch"
  cp -R "$MAIN_REPO/.claude/scratch/issue-${ISSUE_NUM}" "$WORKTREE_PATH/.claude/scratch/"
  echo "  Copied issue-${ISSUE_NUM} attachments into worktree scratch"
else
  echo "[3/6] No .claude/scratch/issue-${ISSUE_NUM:-} dir to mirror — skipping"
fi

# Step 4: Install dependencies
echo "[4/6] Installing dependencies..."
(cd "$WORKTREE_PATH" && eval "$PIPELINE_INSTALL_CMD")

# Step 5: Seed database (if configured)
if [ -n "$PIPELINE_SEED_CMD" ]; then
  echo "[5/6] Seeding database..."
  (cd "$WORKTREE_PATH" && eval "$PIPELINE_SEED_CMD")
else
  echo "[5/6] No seed command configured — skipping"
fi

# Step 6: Determine base branch (if not explicitly provided) and write metadata file
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
  echo "[6/6] Base branch '$BASE_BRANCH' not on remote — pushing..."
  git -C "$MAIN_REPO" push -u origin "$BASE_BRANCH"
fi
mkdir -p "$WORKTREE_PATH/.claude"
echo "$BASE_BRANCH" > "$WORKTREE_PATH/.claude/base-branch"
echo "[6/6] Wrote base branch metadata: $BASE_BRANCH"
# Ignore the untracked base-branch metadata so `gh` doesn't warn about an
# uncommitted change at PR time (#716). `git rev-parse --git-path info/exclude`
# from a linked worktree resolves to the COMMON-DIR exclude (.git/info/exclude),
# which is the only exclude file git honors for ignore resolution — a per-worktree
# .git/worktrees/<name>/info/exclude is NOT consulted (verified, git 2.43.0). The
# ignore is therefore repo-wide; that is acceptable here because `.claude/base-branch`
# is pipeline-managed runtime metadata that must never be committed in any worktree
# or the main checkout. Idempotent.
WT_EXCLUDE="$(git -C "$WORKTREE_PATH" rev-parse --git-path info/exclude)"
case "$WT_EXCLUDE" in /*) : ;; *) WT_EXCLUDE="$WORKTREE_PATH/$WT_EXCLUDE" ;; esac
mkdir -p "$(dirname "$WT_EXCLUDE")"
grep -qxF '.claude/base-branch' "$WT_EXCLUDE" 2>/dev/null \
  || echo '.claude/base-branch' >> "$WT_EXCLUDE"

echo ""
echo "=== Setup complete ==="
echo ""
echo "  Worktree:    $WORKTREE_PATH"
echo "  Base branch: $BASE_BRANCH"
echo "  Execute issue:  claude \"/pipeline:execute-issue-plan <N>\""
