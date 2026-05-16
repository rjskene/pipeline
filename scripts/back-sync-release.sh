#!/bin/bash
# Cherry-picks a release-please release commit from main onto staging.
#
# Usage: scripts/back-sync-release.sh <release-sha>
#
# Clean path:    git cherry-pick -x <sha>  &&  git push origin staging
# Conflict path: opens a draft PR release-back-sync/<short-sha> against staging
#                with conflict markers preserved for human resolution.
# Idempotent:    detects (cherry picked from commit <sha>) trailer on staging
#                and returns early with "already synced".

set -uo pipefail

SHA="${1:-}"
if [ -z "$SHA" ]; then
  echo "usage: $(basename "$0") <release-sha>" >&2
  exit 2
fi

SHORT_SHA="$(git rev-parse --short=8 "$SHA" 2>/dev/null || echo "${SHA:0:8}")"

# ---------------------------------------------------------------------------
# Idempotency guard: if $SHA is already an ancestor of staging (or
# origin/staging), the back-sync already landed. This works for both FF
# (staging IS $SHA) and real-merge (staging is a descendant of $SHA via a
# back-sync merge commit). It is also robust against subsequent commits
# landing on staging AFTER a successful back-sync.
# ---------------------------------------------------------------------------
# Force-update the remote-tracking ref. `git fetch origin staging` (refspec
# without a colon) only writes FETCH_HEAD on older gits; the explicit refspec
# below writes refs/remotes/origin/staging unconditionally.
git fetch -q origin "+refs/heads/staging:refs/remotes/origin/staging" 2>/dev/null \
  || git fetch -q origin || true
git fetch -q origin "$SHA" 2>/dev/null || true
_is_ancestor() {
  git merge-base --is-ancestor "$SHA" "$1" 2>/dev/null
}
if _is_ancestor "origin/staging" || _is_ancestor "refs/heads/staging" || _is_ancestor "refs/remotes/origin/staging"; then
  echo "already synced: $SHA is already an ancestor of staging"
  exit 0
fi

# Check out staging from origin so the cherry-pick lands on the right base.
git checkout -B staging "origin/staging" 2>/dev/null || git checkout staging

# Make sure the release SHA is reachable (workflows use fetch-depth: 0 already).
git fetch -q origin "$SHA" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Clean path: fast-forward staging to the release SHA, push to origin/staging.
# ---------------------------------------------------------------------------
if git merge --ff-only "$SHA"; then
  git push origin staging
  echo "back-sync: fast-forwarded staging to $SHA"
  exit 0
fi

# ---------------------------------------------------------------------------
# Real merge path: FF was not possible (staging has commits ahead of $SHA).
# Favor staging on file collisions (staging is strictly newer for any file
# already shipped to main in the release commit). Use a clear back-sync
# subject so the workflow can identify its own commits idempotently on rerun.
# ---------------------------------------------------------------------------
MERGE_MSG="chore(back-sync): merge release commit $SHORT_SHA from main"
if git merge --no-edit -X ours -m "$MERGE_MSG" "$SHA"; then
  git push origin staging
  echo "back-sync: merged $SHA into staging with -X ours"
  exit 0
fi
git merge --abort 2>/dev/null || true

# ---------------------------------------------------------------------------
# Conflict path: abort, branch off staging, redo cherry-pick leaving conflict
# markers in the tree, commit WIP, push branch, open draft PR.
# ---------------------------------------------------------------------------
git cherry-pick --abort 2>/dev/null || true

BRANCH="release-back-sync/$SHORT_SHA"
git checkout -B "$BRANCH" "origin/staging"

# Redo the cherry-pick; expect non-zero exit. Stage everything (including
# files with conflict markers) and commit so the branch is pushable.
git cherry-pick -x "$SHA" || true
git add -A
git commit --allow-empty -m "WIP: back-sync conflict for $SHA — resolve manually" || true

git push origin "$BRANCH"

BODY_FILE="$(mktemp)"
cat > "$BODY_FILE" <<EOF
Automated back-sync of release commit \`$SHA\` from \`main\` to \`staging\`
hit a cherry-pick conflict. The conflict markers are preserved in the working
tree of this branch — resolve them, commit, and merge this PR to complete the
back-sync.

This PR was opened by \`.github/workflows/back-sync-release.yml\` invoking
\`scripts/back-sync-release.sh\`.
EOF

gh pr create \
  --draft \
  --base staging \
  --head "$BRANCH" \
  --title "chore: back-sync release $SHORT_SHA to staging (conflict)" \
  --body-file "$BODY_FILE"

rm -f "$BODY_FILE"
echo "back-sync: opened draft PR for $SHA (conflict path)"
exit 0
