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

# Fetch origin/staging — swallow network/auth errors.
git -C "$REPO_ROOT" fetch --quiet origin staging 2>/dev/null || exit 0

# Fast-forward only. Non-FF or dirty tree exits non-zero; we swallow and exit 0.
git -C "$REPO_ROOT" merge --ff-only origin/staging 2>/dev/null || true

exit 0
