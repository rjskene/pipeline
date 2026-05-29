#!/usr/bin/env bash
# dogfood-heal-symlink.sh — dogfood-only, heal-ONLY re-assertion of the
# local-marketplace install symlink. Registered on UserPromptSubmit so the
# symlink is restored before every user turn (issue #624).
#
# This is the CHEAP per-prompt path: it delegates to dogfood-symlink-swap.sh
# (a readlink/ln, microseconds) and pays NO `git fetch`/`git merge` cost.
# dogfood-refresh.sh remains the SessionStart fetch+merge+heal path; this
# wrapper closes the mid-session gap that opens when a plugin re-materialization
# (observed: /remote-control connecting) wipes the cache install dir between
# session starts, leaving ${CLAUDE_PLUGIN_ROOT} for the local plugin 404'd.
#
# Idempotent + fail-open: silent, exit 0 always (a UserPromptSubmit hook must
# never block or pollute the prompt).
#
# Env knobs (mostly for tests):
#   DOGFOOD_HEAL_SYMLINK_REPO_ROOT  — override the auto-resolved repo root.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." 2>/dev/null && pwd || true)"
REPO_ROOT="${DOGFOOD_HEAL_SYMLINK_REPO_ROOT:-$REPO_ROOT}"

# Worktree redirect: when invoked from a linked worktree (UserPromptSubmit in a
# feature-branch worktree), target the MAIN repo working tree as the symlink
# source. Mirrors dogfood-symlink-swap.sh lines 28-37 / dogfood-refresh.sh.
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

# Delegate to the already-tested swap helper. No new symlink logic here — only
# a cheaper (no-fetch) trigger path. Fail-open: swallow all output and errors.
SWAP_HELPER="$HERE/dogfood-symlink-swap.sh"
if [ -x "$SWAP_HELPER" ]; then
  DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$REPO_ROOT" bash "$SWAP_HELPER" >/dev/null 2>&1 || true
fi

exit 0
