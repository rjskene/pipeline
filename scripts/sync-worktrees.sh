#!/bin/bash
set -euo pipefail

# Run from the consumer repo root (so `$(pwd)/pipeline.config` resolves), or
# export PIPELINE_PROJECT_ROOT to override the lookup directory.
source "${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config"

# Sync untracked .claude/ files to all active worktrees and verify setup health.
# Usage: bash ${CLAUDE_PLUGIN_ROOT}/scripts/sync-worktrees.sh

MAIN_REPO="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
ISSUES=0

# ---------------------------------------------------------------------------
# Prune remote feature/* branches whose PR is merged or closed
# ---------------------------------------------------------------------------
prune_orphaned_branches() {
  # Read ALLOW_DELETIONS from settings.local.json
  ALLOW_DELETIONS="$(jq -r '.env.ALLOW_DELETIONS // empty' "$MAIN_REPO/.claude/settings.local.json" 2>/dev/null || echo "")"

  echo ""
  echo "=== Orphaned Branch Pruning ==="

  if [ "$ALLOW_DELETIONS" != "true" ]; then
    echo "  [skip] ALLOW_DELETIONS != true in settings.local.json"
    echo "  Set ALLOW_DELETIONS=true to enable automated branch pruning."
    return 0
  fi

  # Fetch remote branch list
  git -C "$MAIN_REPO" fetch --prune --quiet 2>/dev/null || true
  REMOTE_BRANCHES="$(git -C "$MAIN_REPO" branch -r --list 'origin/feature/*' 2>/dev/null || echo "")"

  if [ -z "$REMOTE_BRANCHES" ]; then
    echo "  No remote feature/* branches found."
    return 0
  fi

  CHECKED=0
  PRUNED=0

  while IFS= read -r remote_branch; do
    # Strip leading whitespace and "origin/" prefix
    BRANCH="$(echo "$remote_branch" | sed 's|^ *origin/||')"

    # Skip origin/HEAD pseudo-ref
    [ "$BRANCH" = "HEAD" ] && continue
    # Skip non-feature branches (redundant with glob but defensive)
    [[ "$BRANCH" == feature/* ]] || continue

    CHECKED=$((CHECKED + 1))

    # Skip branches currently checked out in a worktree (brackets required)
    if git -C "$MAIN_REPO" worktree list | grep -qF "[$BRANCH]"; then
      echo "  [skip] $BRANCH — currently checked out in a worktree"
      continue
    fi

    # Query GitHub for any PR with this branch as head
    PR_JSON="$(gh pr list --repo "$PIPELINE_REPO" --head "$BRANCH" --state all \
      --json state,number --jq '.[0] // empty' 2>/dev/null || echo "")"

    if [ -z "$PR_JSON" ]; then
      echo "  [warn]  $BRANCH — no PR found; skipping (manual cleanup if needed)"
      continue
    fi

    PR_STATE="$(echo "$PR_JSON" | jq -r '.state')"
    PR_NUM="$(echo "$PR_JSON" | jq -r '.number')"

    if [ "$PR_STATE" = "OPEN" ]; then
      echo "  [skip]  $BRANCH (PR #$PR_NUM — OPEN)"
      continue
    fi

    # PR is MERGED or CLOSED — prune
    REMOTE_DELETED="no"
    LOCAL_DELETED="no"

    git -C "$MAIN_REPO" push origin --delete "$BRANCH" 2>/dev/null \
      && REMOTE_DELETED="yes" || true
    git -C "$MAIN_REPO" branch -D "$BRANCH" 2>/dev/null \
      && LOCAL_DELETED="yes" || true

    echo "  [pruned] $BRANCH (PR #$PR_NUM — $PR_STATE) — remote: $REMOTE_DELETED, local: $LOCAL_DELETED"
    PRUNED=$((PRUNED + 1))
  done <<< "$REMOTE_BRANCHES"

  echo "  Checked $CHECKED remote feature/* branch(es)"
  if [ $PRUNED -gt 0 ]; then
    echo "  === Pruned $PRUNED branch(es) ==="
  else
    echo "  === No orphaned branches found ==="
  fi
}

echo "=== Worktree Sync ==="
echo "  Main repo: $MAIN_REPO"
echo ""

# Collect worktree paths (skip the main repo itself)
WORKTREES=()
while IFS= read -r line; do
  wt_path="$(echo "$line" | awk '{print $1}')"
  [ "$wt_path" = "$MAIN_REPO" ] && continue
  WORKTREES+=("$wt_path")
done < <(git -C "$MAIN_REPO" worktree list)

if [ ${#WORKTREES[@]} -eq 0 ]; then
  echo "No worktrees found."
  exit 0
fi

for wt in "${WORKTREES[@]}"; do
  wt_name="$(basename "$wt")"
  echo "--- $wt_name ---"

  # 1. Check settings.local.json
  if [ -f "$wt/.claude/settings.local.json" ]; then
    if diff -q "$MAIN_REPO/.claude/settings.local.json" "$wt/.claude/settings.local.json" >/dev/null 2>&1; then
      echo "  [ok] settings.local.json"
    else
      echo "  [fix] settings.local.json (outdated — updating)"
      cp "$MAIN_REPO/.claude/settings.local.json" "$wt/.claude/settings.local.json"
      ISSUES=$((ISSUES + 1))
    fi
  else
    echo "  [fix] settings.local.json (missing — copying)"
    mkdir -p "$wt/.claude"
    cp "$MAIN_REPO/.claude/settings.local.json" "$wt/.claude/settings.local.json"
    ISSUES=$((ISSUES + 1))
  fi

  # 2. Check untracked hooks
  for hook in "$MAIN_REPO/.claude/hooks/"*; do
    [ -f "$hook" ] || continue
    fname="$(basename "$hook")"
    # Only sync untracked hooks (tracked ones come from git)
    if git -C "$MAIN_REPO" ls-files --error-unmatch ".claude/hooks/$fname" >/dev/null 2>&1; then
      continue
    fi
    if [ -f "$wt/.claude/hooks/$fname" ]; then
      if diff -q "$hook" "$wt/.claude/hooks/$fname" >/dev/null 2>&1; then
        echo "  [ok] hooks/$fname"
      else
        echo "  [fix] hooks/$fname (outdated — updating)"
        cp "$hook" "$wt/.claude/hooks/$fname"
        ISSUES=$((ISSUES + 1))
      fi
    else
      echo "  [fix] hooks/$fname (missing — copying)"
      mkdir -p "$wt/.claude/hooks"
      cp "$hook" "$wt/.claude/hooks/$fname"
      ISSUES=$((ISSUES + 1))
    fi
  done

  # 3. Sync plan files
  if [ -d "$MAIN_REPO/.claude/plans" ]; then
    for plan in "$MAIN_REPO/.claude/plans/"*; do
      [ -f "$plan" ] || continue
      fname="$(basename "$plan")"
      if [ -f "$wt/.claude/plans/$fname" ]; then
        if diff -q "$plan" "$wt/.claude/plans/$fname" >/dev/null 2>&1; then
          echo "  [ok] plans/$fname"
        else
          echo "  [fix] plans/$fname (outdated — updating)"
          cp "$plan" "$wt/.claude/plans/$fname"
          ISSUES=$((ISSUES + 1))
        fi
      else
        echo "  [fix] plans/$fname (missing — copying)"
        mkdir -p "$wt/.claude/plans"
        cp "$plan" "$wt/.claude/plans/$fname"
        ISSUES=$((ISSUES + 1))
      fi
    done
  fi

  # 4. Sync additional files (e.g., .mcp.json)
  for syncfile in $PIPELINE_SYNC_FILES; do
    if [ -f "$MAIN_REPO/$syncfile" ]; then
      if [ -f "$wt/$syncfile" ]; then
        if diff -q "$MAIN_REPO/$syncfile" "$wt/$syncfile" >/dev/null 2>&1; then
          echo "  [ok] $syncfile"
        else
          echo "  [fix] $syncfile (outdated — updating)"
          cp "$MAIN_REPO/$syncfile" "$wt/$syncfile"
          ISSUES=$((ISSUES + 1))
        fi
      else
        echo "  [fix] $syncfile (missing — copying)"
        cp "$MAIN_REPO/$syncfile" "$wt/$syncfile"
        ISSUES=$((ISSUES + 1))
      fi
    fi
  done

  # 5. Sync CLAUDE.md / doc files (tracked, but worktrees may be on older commits)
  for mdfile in $PIPELINE_SYNC_DOCS; do
    if [ -f "$MAIN_REPO/$mdfile" ]; then
      if [ -f "$wt/$mdfile" ]; then
        if diff -q "$MAIN_REPO/$mdfile" "$wt/$mdfile" >/dev/null 2>&1; then
          echo "  [ok] $mdfile"
        else
          echo "  [fix] $mdfile (outdated — updating)"
          cp "$MAIN_REPO/$mdfile" "$wt/$mdfile"
          ISSUES=$((ISSUES + 1))
        fi
      else
        echo "  [skip] $mdfile (path does not exist in worktree)"
      fi
    fi
  done

  # 6. Mirror per-issue scratch attachments. Parse the issue number from the
  # worktree basename suffix (PIPELINE_WORKTREE_PREFIX-<N>-<slug>); copy any
  # files from MAIN_REPO/.claude/scratch/issue-<N>/ that aren't already in the
  # worktree. cp -Rn preserves the portable idiom (no rsync dependency).
  wt_base="$(basename "$wt")"
  scratch_n=""
  if [[ "$wt_base" =~ ^${PIPELINE_WORKTREE_PREFIX}-([0-9]+)- ]]; then
    scratch_n="${BASH_REMATCH[1]}"
  fi
  if [ -n "$scratch_n" ] && [ -d "$MAIN_REPO/.claude/scratch/issue-${scratch_n}" ]; then
    mkdir -p "$wt/.claude/scratch"
    cp -Rn "$MAIN_REPO/.claude/scratch/issue-${scratch_n}" "$wt/.claude/scratch/" 2>/dev/null || true
    echo "  [ok] scratch/issue-${scratch_n} mirrored"
  fi

  echo ""
done

# Run orphaned branch pruning after worktree sync
prune_orphaned_branches

if [ $ISSUES -eq 0 ]; then
  echo "=== All worktrees in sync ==="
else
  echo "=== Fixed $ISSUES issue(s) ==="
fi
