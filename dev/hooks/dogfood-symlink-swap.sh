#!/usr/bin/env bash
# dogfood-symlink-swap.sh — dogfood-only self-heal of the local-marketplace
# install path. Replaces the cache install directory that Claude Code creates
# at `/plugin install pipeline@claude-pipeline-local` time with a symlink to
# the repo working tree, so `git pull` on staging = live skill/hook updates
# in the next session (the dogfood-as-live promise).
#
# Reads `~/.claude/plugins/installed_plugins.json`, picks the array entry
# under `pipeline@claude-pipeline-local` whose `.projectPath` equals the
# resolved REPO_ROOT, and replaces that entry's `.installPath` directory
# with a symlink to REPO_ROOT.
#
# Invoked from dev/hooks/dogfood-refresh.sh after the ff-merge. Also usable
# standalone via `bash dev/hooks/dogfood-symlink-swap.sh`.
#
# Fail-open at every step (missing jq, missing/bad JSON, no matching entry,
# ln/rm failure). Parent SessionStart hook MUST never block.
#
# Env knobs (mostly for tests):
#   DOGFOOD_SYMLINK_SWAP_REPO_ROOT  — override the auto-resolved repo root.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." 2>/dev/null && pwd || true)"
REPO_ROOT="${DOGFOOD_SYMLINK_SWAP_REPO_ROOT:-$REPO_ROOT}"

# Worktree redirect: when invoked from a linked worktree (SessionStart hook in
# a feature-branch worktree), use the MAIN repo working tree as the symlink
# target. Mirrors dogfood-refresh.sh lines 35-41.
if [ -n "${REPO_ROOT:-}" ] && [ -d "$REPO_ROOT" ]; then
  MAIN_REPO="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
               | awk '/^worktree / {print $2; exit}')"
  if [ -n "$MAIN_REPO" ] && [ -d "$MAIN_REPO" ]; then
    REPO_ROOT="$MAIN_REPO"
  fi
fi

if [ -z "${REPO_ROOT:-}" ] || [ ! -d "$REPO_ROOT" ]; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

IP_PATH="${HOME}/.claude/plugins/installed_plugins.json"
[ -f "$IP_PATH" ] || exit 0

INSTALL_PATH="$(jq -r --arg root "$REPO_ROOT" '
  .plugins["pipeline@claude-pipeline-local"] // []
  | map(select(.projectPath == $root)) | .[0].installPath // ""
' "$IP_PATH" 2>/dev/null)"

[ -z "$INSTALL_PATH" ] && exit 0
[ "$INSTALL_PATH" = "null" ] && exit 0

if [ -L "$INSTALL_PATH" ]; then
  CURRENT="$(readlink "$INSTALL_PATH" 2>/dev/null || true)"
  if [ "$CURRENT" = "$REPO_ROOT" ]; then
    exit 0
  fi
  rm -f "$INSTALL_PATH" 2>/dev/null || exit 0
elif [ -d "$INSTALL_PATH" ]; then
  rm -rf "$INSTALL_PATH" 2>/dev/null || exit 0
fi

mkdir -p "$(dirname "$INSTALL_PATH")" 2>/dev/null || exit 0
ln -s "$REPO_ROOT" "$INSTALL_PATH" 2>/dev/null || true

exit 0
