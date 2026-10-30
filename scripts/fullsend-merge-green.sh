#!/usr/bin/env bash
# fullsend-merge-green.sh — auto-merge-gate step 3: the green merge loop, ONE
# call per wave over the issues whose Step 7 GATE line read reason=green.
#
# LINE ORDER IS LOAD-BEARING — do not reorder:
#   PR derivation (fail-closed) -> TOCTOU baseRefName re-read -> re-gate
#   (auto_merge_should_fire on live PR state; non-green => MERGE: reason=<token>,
#   no merge) -> guarded
#   `gh pr merge --merge --delete-branch` (synchronous, never auto-merge; a
#   "Head branch is out of date" refusal sleeps, re-gates and retries, bounded
#   by PIPELINE_MERGE_RETRY_MAX) -> merge
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
  MERGE: issue=#<N> pr=#<P> reason=<green|block-base-mismatch|block-no-pr|block-merge-failed|<any fullsend-gate.sh block-* token>> [sha=<sha>] [detail="<first stderr line, <=120 chars>"]
Every block-* line still needs fullsend-block-merge.sh. Exit 1 only on a
genuine `gh issue close` failure (fail-loud).
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH, PIPELINE_PROJECT_ROOT,
PIPELINE_WORKTREE_PREFIX, PIPELINE_SCREENSHOT_REWRITE_ENABLED (default true),
PIPELINE_MERGE_RETRY_MAX (default 3), PIPELINE_MERGEABILITY_POLL_SECS (default 5).
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
# shellcheck source=scripts/_fullsend-resolve-pr.sh
source "$SELF_DIR/_fullsend-resolve-pr.sh"

source "$SELF_DIR/auto-merge-gate.sh"
CR_LINE=$(bash "$SELF_DIR/check-capability-refusal.sh" --resolve-sources)
CR_STATE=${CR_LINE%% *}; CR_STATE=${CR_STATE#SOURCES=}
case "$CR_STATE" in
  resolved)                     export PIPELINE_CAPABILITY_REFUSAL_SOURCES="${CR_LINE##*DIR=}" ;;
  no-log-dir|unresolvable-root) echo "NOTE: capability arm skipped/DORMANT: $CR_LINE" >&2 ;;
esac

for N in "$@"; do
  ISSUE="$N"
  fullsend_resolve_pr "$N"
  [ -n "$PR_NUM" ] || { echo "MERGE: issue=#$ISSUE pr=#none reason=block-no-pr"; continue; }
  BASE_RECHECK=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json baseRefName --jq .baseRefName 2>/dev/null)
  if [ -z "$BASE_RECHECK" ] || [ "$BASE_RECHECK" != "$PIPELINE_BASE_BRANCH" ]; then
    REASON="block-base-mismatch"
    echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=$REASON"; continue
  fi
  REGATE=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
  [ "$REGATE" = green ] || { echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=$REGATE"; continue; }
  MAX=${PIPELINE_MERGE_RETRY_MAX:-3}; SECS=${PIPELINE_MERGEABILITY_POLL_SECS:-5}; k=0
  while :; do
    # stderr-only capture: gh stdout stays on stdout (fd 3), MERR gets stderr.
    { MERR=$(gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch 2>&1 1>&3 3>&-); MRC=$?; } 3>&1
    [ -n "$MERR" ] && printf '%s\n' "$MERR" >&2
    [ "$MRC" -eq 0 ] && break
    if printf '%s' "$MERR" | grep -qi 'head branch is out of date' && [ "$k" -lt "$MAX" ]; then
      k=$((k + 1))
      echo "fullsend-merge-green: pr=#$PR_NUM merge refused (head out of date), retry $k/$MAX in ${SECS}s" >&2
      sleep "$SECS"
      REGATE=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
      [ "$REGATE" = green ] || { echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=$REGATE"; continue 2; }
      continue
    fi
    DETAIL=$(printf '%s\n' "$MERR" | head -1 | tr -d '"\r' | sed 's/ reason=/ reason:/g' | cut -c1-120)
    if [ -n "$DETAIL" ]; then
      echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=block-merge-failed detail=\"$DETAIL\""
    else
      echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=block-merge-failed"
    fi
    continue 2
  done
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
