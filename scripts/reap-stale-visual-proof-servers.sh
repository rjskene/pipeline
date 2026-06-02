#!/bin/bash
# reap-stale-visual-proof-servers.sh — kill orphan `python -m http.server`
# processes whose backing worktree has been pruned.
#
# Visual-proof evaluators (see skills/evaluate-issue-pr and related) spawn
# short-lived python http.servers rooted at a worktree directory. If the
# worktree is removed (cleanup-worktree.sh, manual rm, container teardown)
# while the server is still bound to a port, the process leaks. This helper
# enumerates such servers, identifies each one's enclosing `.git` ancestor,
# cross-checks against the live `git worktree list`, and SIGTERM/SIGKILLs
# any whose worktree is no longer registered.
#
# Output, one line per kill:
#   EVENT: reaped pid=<P> dir=<D>
# When no matching processes are found (or all matches are live):
#   (no stale servers)
#
# Exits 0 regardless of how many (or zero) processes were reaped — the
# reaper is housekeeping, never gate-fatal.
set -euo pipefail

# Discover orchestrator repo root for the `git worktree list` cross-check.
# Default to PWD; callers (skills/status Step 0) typically already cd'd to the
# orchestrator base. Fall back to PWD if `git -C` fails.
WORKTREE_BASE="${PIPELINE_REPO_ROOT:-$(pwd)}"

# Build the set of live worktree paths (one per line).
live_worktrees=$(git -C "$WORKTREE_BASE" worktree list --porcelain 2>/dev/null \
                   | awk '/^worktree /{ $1=""; sub(/^ /,""); print }') || live_worktrees=""

# Enumerate matching processes. `pgrep -af` prints `<pid> <cmdline>` lines.
# We match both `python -m http.server` and `python3 -m http.server`.
matches=$(pgrep -af 'python3? -m http\.server' 2>/dev/null || true)

if [ -z "$matches" ]; then
  echo "(no stale servers)"
  exit 0
fi

reaped=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  pid="${line%% *}"
  cmdline="${line#* }"

  # Parse `--directory <dir>` out of the cmdline. Use awk to handle both
  # `--directory foo` and (unlikely) `--directory=foo`.
  dir=$(echo "$cmdline" | awk '
    {
      for (i=1; i<=NF; i++) {
        if ($i == "--directory" && i < NF) { print $(i+1); exit }
        if ($i ~ /^--directory=/)         { sub(/^--directory=/,"",$i); print $i; exit }
      }
    }')

  # No --directory → cannot classify; leave it alone (don't kill blind).
  [ -z "$dir" ] && continue

  # Walk upward to find the enclosing `.git` (file or dir; worktrees have
  # a `.git` *file* pointing into the main repo's worktrees/<name>).
  # If the directory was rm -rf'd, this loop bottoms out at / with no match
  # → treat as stale.
  candidate="$dir"
  enclosing_worktree=""
  while [ -n "$candidate" ] && [ "$candidate" != "/" ]; do
    if [ -e "$candidate/.git" ]; then
      enclosing_worktree="$candidate"
      break
    fi
    candidate=$(dirname "$candidate")
  done

  # Decide staleness.
  #   - No enclosing `.git` → directory is gone → stale.
  #   - Enclosing `.git` exists but not in `git worktree list` → stale.
  #   - Enclosing `.git` is in the live list → live, skip.
  stale=0
  if [ -z "$enclosing_worktree" ]; then
    stale=1
  else
    if ! printf '%s\n' "$live_worktrees" | grep -Fxq "$enclosing_worktree"; then
      stale=1
    fi
  fi

  [ "$stale" -eq 0 ] && continue

  # SIGTERM, sleep 2, SIGKILL if still alive.
  kill -TERM "$pid" 2>/dev/null || true
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  echo "EVENT: reaped pid=$pid dir=$dir"
  reaped=$((reaped + 1))
done <<< "$matches"

if [ "$reaped" -eq 0 ]; then
  echo "(no stale servers)"
fi

exit 0
