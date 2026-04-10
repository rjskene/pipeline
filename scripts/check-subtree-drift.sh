#!/bin/bash
set -euo pipefail

# check-subtree-drift.sh — Detect when .claude-pipeline/ is out of sync
# with the source repo in either direction.
#
# Usage: bash .claude/scripts/check-subtree-drift.sh [--quiet]
#   --quiet: only print if drift is detected
#
# Exit codes:
#   0 = in sync (or detection skipped)
#   2 = upstream ahead
#   3 = local ahead
#   4 = bidirectional drift

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true

# Find project root (two levels up from .claude/scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$SCRIPT_DIR" == *".claude/scripts"* ]]; then
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
elif [[ "$SCRIPT_DIR" == *".claude-pipeline/scripts"* ]]; then
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

PREFIX=".claude-pipeline"

# Source config if available
CONFIG_FILE="$PROJECT_ROOT/pipeline.config"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

REMOTE="${PIPELINE_SUBTREE_REMOTE:-}"
BRANCH="${PIPELINE_SUBTREE_BRANCH:-main}"

cd "$PROJECT_ROOT"

# --- Check if this is a git repo ---
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  $QUIET || echo "  [skip] Not a git repository"
  exit 0
fi

# --- Check if .claude-pipeline/ exists ---
if [ ! -d "$PREFIX" ]; then
  $QUIET || echo "  [skip] No $PREFIX directory found"
  exit 0
fi

# --- Detect install method ---
# Submodule?
if git submodule status "$PREFIX" >/dev/null 2>&1 && git submodule status "$PREFIX" 2>/dev/null | grep -q .; then
  $QUIET || echo "  [skip] $PREFIX is a submodule — use 'git submodule update' to sync"
  exit 0
fi

# Subtree? Look for git-subtree-split metadata
SPLIT_LINE=$(git log --all --format='%b' | grep "git-subtree-dir: $PREFIX" -A1 | grep "git-subtree-split:" | head -1 || true)

if [ -z "$SPLIT_LINE" ]; then
  $QUIET || echo "  [skip] No subtree metadata found — likely a plain copy (cannot detect drift)"
  exit 0
fi

LAST_SYNCED_HASH=$(echo "$SPLIT_LINE" | sed 's/.*git-subtree-split: //' | tr -d '[:space:]')

if [ -z "$LAST_SYNCED_HASH" ]; then
  $QUIET || echo "  [skip] Could not parse subtree-split hash"
  exit 0
fi

# --- Auto-detect remote if not configured ---
if [ -z "$REMOTE" ]; then
  REMOTE=$(git remote -v 2>/dev/null | grep -i 'claude-pipeline' | head -1 | awk '{print $1}' || true)
fi

if [ -z "$REMOTE" ]; then
  $QUIET || echo "  [warn] No subtree remote found. Add with:"
  $QUIET || echo "         git remote add claude-pipeline <url>"
  exit 0
fi

# --- Fetch upstream (graceful failure) ---
if ! git fetch "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
  $QUIET || echo "  [skip] Could not fetch from remote '$REMOTE' (offline or missing remote)"
  exit 0
fi

# --- Check upstream-ahead ---
UPSTREAM_AHEAD=$(git log --oneline "$LAST_SYNCED_HASH..FETCH_HEAD" 2>/dev/null | wc -l | tr -d ' ')

# --- Check local-ahead ---
# Find the most recent commit that merged the subtree (add or pull)
MERGE_COMMIT=$(git log --all --format='%H %s' | grep "'$PREFIX'" | head -1 | awk '{print $1}' || true)

LOCAL_AHEAD=0
if [ -n "$MERGE_COMMIT" ]; then
  LOCAL_AHEAD=$(git log --oneline "$MERGE_COMMIT..HEAD" -- "$PREFIX/" 2>/dev/null | wc -l | tr -d ' ')
fi

# --- Report ---
DRIFT_CODE=0

if [ "$UPSTREAM_AHEAD" -gt 0 ] && [ "$LOCAL_AHEAD" -gt 0 ]; then
  DRIFT_CODE=4
elif [ "$UPSTREAM_AHEAD" -gt 0 ]; then
  DRIFT_CODE=2
elif [ "$LOCAL_AHEAD" -gt 0 ]; then
  DRIFT_CODE=3
fi

if [ "$DRIFT_CODE" -eq 0 ]; then
  $QUIET || echo "  [ok] $PREFIX is in sync with $REMOTE/$BRANCH"
  exit 0
fi

# Drift detected — always print (even in quiet mode)
REMOTE_URL=$(git remote get-url "$REMOTE" 2>/dev/null || echo "$REMOTE")
SYNC_DATE=$(git log -1 --format='%ci' "$LAST_SYNCED_HASH" 2>/dev/null | cut -d' ' -f1 || echo "unknown")

echo ""
echo "=== Subtree Drift Check ==="
echo "  Remote: $REMOTE ($REMOTE_URL)"
echo "  Last synced: ${LAST_SYNCED_HASH:0:7} ($SYNC_DATE)"

if [ "$UPSTREAM_AHEAD" -gt 0 ]; then
  echo "  Upstream: $UPSTREAM_AHEAD commit(s) ahead"
fi
if [ "$LOCAL_AHEAD" -gt 0 ]; then
  echo "  Local: $LOCAL_AHEAD commit(s) ahead"
fi

echo ""
if [ "$DRIFT_CODE" -eq 4 ]; then
  echo "  BIDIRECTIONAL DRIFT — both sides have changes"
  echo "  → Pull upstream:  git subtree pull --prefix=$PREFIX $REMOTE $BRANCH --squash"
  echo "  → Push local:     git subtree push --prefix=$PREFIX $REMOTE $BRANCH"
  echo "  (pull first to incorporate upstream, then push to share local changes)"
elif [ "$DRIFT_CODE" -eq 2 ]; then
  echo "  UPSTREAM AHEAD — source repo has new changes"
  echo "  → Pull updates:   git subtree pull --prefix=$PREFIX $REMOTE $BRANCH --squash"
elif [ "$DRIFT_CODE" -eq 3 ]; then
  echo "  LOCAL AHEAD — you have unpushed pipeline changes"
  echo "  → Push to source: git subtree push --prefix=$PREFIX $REMOTE $BRANCH"
fi
echo ""

exit "$DRIFT_CODE"
