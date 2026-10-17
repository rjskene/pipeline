#!/usr/bin/env bash
# fullsend-merge-green.sh — auto-merge-gate step 3: the green merge loop, ONE
# call per wave over the issues whose Step 7 GATE line read reason=green.
#
# LINE ORDER IS LOAD-BEARING — do not reorder:
#   PR derivation (fail-closed) -> TOCTOU baseRefName re-read -> guarded
#   `gh pr merge --merge --delete-branch` (synchronous, never --auto) -> merge
#   SHA capture -> screenshot-URL rewrite (after the SHA it pins to, before the
#   footer) -> `Auto-merged:` footer -> green MERGE: line (before the label flip,
#   so the fail-loud exit below can never hide a completed merge) ->
#   finalize-issue-labels.sh -> issue close (an "already closed" stderr is
#   benign: gh pr merge auto-closes via closingIssuesReferences).
# A genuine close failure exits 1 and ABORTS the remaining merges; Step 8's
# fallback pass re-gates any pr-open issue left unmerged.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-merge-green.sh <N>...

Merges each greenlit issue's PR and prints ONE line per issue:
  MERGE: issue=#<N> pr=#<P> reason=<green|block-base-mismatch|block-no-pr|block-merge-failed> [sha=<sha>]
Every block-* line still needs fullsend-block-merge.sh. Exit 1 only on a
genuine `gh issue close` failure (fail-loud).
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH, PIPELINE_PROJECT_ROOT,
PIPELINE_WORKTREE_PREFIX, PIPELINE_SCREENSHOT_REWRITE_ENABLED (default true).
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
# shellcheck source=scripts/_fullsend-resolve-pr.sh
source "$SELF_DIR/_fullsend-resolve-pr.sh"

for N in "$@"; do
  ISSUE="$N"
  fullsend_resolve_pr "$N"
  [ -n "$PR_NUM" ] || { echo "MERGE: issue=#$ISSUE pr=#none reason=block-no-pr"; continue; }
  BASE_RECHECK=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json baseRefName --jq .baseRefName 2>/dev/null)
  if [ -z "$BASE_RECHECK" ] || [ "$BASE_RECHECK" != "$PIPELINE_BASE_BRANCH" ]; then
    REASON="block-base-mismatch"
    echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=$REASON"; continue
  fi
  gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch \
    || { echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=block-merge-failed"; continue; }
  SHA=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json mergeCommit --jq .mergeCommit.oid)
  if [ -n "$SHA" ] && [ "${PIPELINE_SCREENSHOT_REWRITE_ENABLED:-true}" = "true" ]; then
    bash "$SELF_DIR/rewrite-eval-screenshot-urls.sh" "$PR_NUM" "$SHA" \
      || echo "WARN: post-merge URL rewrite failed for PR #${PR_NUM}"
  fi
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  FOOTER="Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at ${TS}"
  gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" --body "$FOOTER"
  echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=green sha=${SHA:-none}"
  bash "$SELF_DIR/finalize-issue-labels.sh" "$ISSUE" --repo "$PIPELINE_REPO" \
    || echo "WARN: finalize-issue-labels exited non-zero for issue #${ISSUE}; labels may be stale (merge already completed)."
  CLOSE_SUFFIX=$([ -n "$SHA" ] && echo " (${SHA})" || echo "")
  CLOSE_ERR=$(gh issue close "$ISSUE" --repo "$PIPELINE_REPO" --comment "Merged via #${PR_NUM}${CLOSE_SUFFIX}. ${FOOTER}" 2>&1)
  if [ $? -ne 0 ]; then
    if printf '%s' "$CLOSE_ERR" | grep -qi 'already closed'; then
      echo "Issue #${ISSUE} already closed by gh pr merge (closingIssuesReferences) — benign."
    else
      echo "$CLOSE_ERR" >&2
      exit 1
    fi
  fi
done
exit 0
