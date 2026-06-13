#!/bin/bash
set -euo pipefail

# check-branch-cruft.sh — pre-PR guard (#1015/#1028).
#
# Inspects the COMMITTED branch-vs-base diff (NOT the staged index) and refuses if
# any path added/changed on this branch is a known cruft path that should never be
# committed. By Step 9 of execute-issue-plan the executor has already committed all
# work via red→green→commit, so the staged index is empty at PR time — only the
# committed diff reveals cruft swept into a feature commit (the #1015 failure mode,
# where two `.claude/migration-cleanup-*` files entered PR #1026 inside a normal commit).
#
# Deterministic DENYLIST — no plan-surface inference. Runs from the worktree root
# (caller cwd), mirroring how other Step 9 helpers (e.g. derive-pr-title.sh) are invoked.

# Pick up PIPELINE_BASE_BRANCH from pipeline.config when not exported.
[ -f pipeline.config ] && source ./pipeline.config 2>/dev/null || true
: "${PIPELINE_BASE_BRANCH:?check-branch-cruft: PIPELINE_BASE_BRANCH unset}"

# Compute the committed branch-vs-base diff. If the base ref is unresolvable
# (detached/odd state), fall back to inspecting only the HEAD commit and note it.
if CHANGED=$(git diff --name-only "$PIPELINE_BASE_BRANCH"..HEAD 2>/dev/null); then
  :
else
  echo "check-branch-cruft: NOTE base ref '$PIPELINE_BASE_BRANCH' unresolvable; inspecting HEAD commit only (degraded mode)." >&2
  CHANGED=$(git diff-tree -r --name-only --no-commit-id HEAD)
fi

# Deterministic cruft denylist (anchored, repo-relative path regexes).
DENYLIST=(
  '^\.claude/migration-cleanup-'        # the #1015/#1028 stray report+patch
  '^\.claude/logs/'
  '^\.claude/scratch/'
  '^\.claude/worktrees/'
  '^\.claude/settings\.local\.json$'
  '^pipeline\.config$'
  '^\.claude/[^/]+\.patch$'             # any stray *.patch directly under .claude/
)

VIOLATIONS=()
N=0
while IFS= read -r path; do
  [ -z "$path" ] && continue
  N=$((N + 1))
  for rx in "${DENYLIST[@]}"; do
    if printf '%s' "$path" | grep -Eq "$rx"; then
      VIOLATIONS+=("$path")
      break
    fi
  done
done <<< "$CHANGED"

if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
  echo "check-branch-cruft: refusing — branch-vs-base diff contains cruft paths that should never be committed:" >&2
  for v in "${VIOLATIONS[@]}"; do
    echo "  $v" >&2
  done
  exit 1
fi

echo "check-branch-cruft: OK ($N changed paths vs $PIPELINE_BASE_BRANCH, no cruft)"
exit 0
