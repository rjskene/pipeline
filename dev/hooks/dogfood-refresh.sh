#!/usr/bin/env bash
# dogfood-refresh.sh — dogfood-only auto-refresh of the local marketplace repo working tree.
#
# Single source for BOTH:
#   - SessionStart hook in dogfood-local .claude/settings.json
#   - operator-driven manual command: bash dev/hooks/dogfood-refresh.sh
#
# Behavior:
#   - `git fetch origin staging` then `git merge --ff-only origin/staging` in the
#     repo working tree (NOT cwd — resolved from this script's location).
#   - When invoked from a linked worktree, redirects REPO_ROOT to the MAIN
#     repo working tree so worktree sessions refresh staging without
#     disturbing the worktree's own feature branch (plan Risk #5, #611).
#   - Idempotent. <2s on the no-op happy path (git fetch is the dominant cost).
#   - Exits 0 on ALL failure modes (no network, dirty tree, non-FF state,
#     missing git binary). MUST never block session start.
#   - Logging:
#       PIPELINE_LOGS_ENABLED=true  → appends to .claude/logs/dogfood-refresh.log
#       otherwise                   → silent (>/dev/null 2>&1)
#
# Env knobs (mostly for tests):
#   DOGFOOD_REFRESH_REPO_ROOT  — override the auto-resolved repo root so tests
#                                can point at a fixture clone.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." 2>/dev/null && pwd || true)"
REPO_ROOT="${DOGFOOD_REFRESH_REPO_ROOT:-$REPO_ROOT}"

# If REPO_ROOT is a linked worktree (e.g., the SessionStart hook fired from
# a feature-branch worktree), redirect to the main repo working tree.
# `git worktree list --porcelain` always lists the main worktree FIRST.
# Fail-open: any error keeps the current REPO_ROOT.
if [ -n "${REPO_ROOT:-}" ] && [ -d "$REPO_ROOT" ]; then
  MAIN_REPO="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
               | awk '/^worktree / {print $2; exit}')"
  if [ -n "$MAIN_REPO" ] && [ -d "$MAIN_REPO" ]; then
    REPO_ROOT="$MAIN_REPO"
  fi
fi

# Bail (exit 0) if REPO_ROOT empty or not a directory.
if [ -z "${REPO_ROOT:-}" ] || [ ! -d "$REPO_ROOT" ]; then
  exit 0
fi

# Logging redirect — opt-in via PIPELINE_LOGS_ENABLED. Fail-open everywhere.
if [ "${PIPELINE_LOGS_ENABLED:-false}" = "true" ]; then
  LOG_DIR="$REPO_ROOT/.claude/logs"
  LOG_FILE="$LOG_DIR/dogfood-refresh.log"
  { mkdir -p "$LOG_DIR"; } 2>/dev/null || true
  exec >>"$LOG_FILE" 2>&1 || exec >/dev/null 2>&1
else
  exec >/dev/null 2>&1
fi

# Missing git binary → no-op.
command -v git >/dev/null 2>&1 || exit 0

# Must be a real git working tree.
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Only fast-forward HEAD onto origin/staging when HEAD IS staging (#1274 scope
# 4). On any other branch (e.g. this clone's `evolve` integration branch),
# fast-forwarding would silently overwrite that branch's own history with
# staging's — the literal below must match the hardcoded `origin/staging`
# merge target, so this deliberately does NOT read $PIPELINE_BASE_BRANCH.
# The swap helper below still runs regardless of branch.
if [ "$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null)" = "staging" ]; then
  # Fetch origin/staging — swallow network/auth errors.
  git -C "$REPO_ROOT" fetch --quiet origin staging 2>/dev/null || exit 0

  # Fast-forward only. Non-FF or dirty tree exits non-zero; we swallow and exit 0.
  git -C "$REPO_ROOT" merge --ff-only origin/staging 2>/dev/null || true
fi

# Self-heal the local-marketplace install path into a symlink to the working
# tree. Fail-open: the helper's own || true keeps refresh exit 0 regardless.
SWAP_HELPER="$HERE/dogfood-symlink-swap.sh"
if [ -x "$SWAP_HELPER" ]; then
  DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$REPO_ROOT" bash "$SWAP_HELPER" 2>/dev/null || true
fi

exit 0
