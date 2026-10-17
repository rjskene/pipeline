#!/usr/bin/env bash
# fullsend-block-merge.sh — auto-merge-gate step 4: route every block-* GATE /
# MERGE line. Posts ONE `Auto-merge skipped:` comment on the PR (a
# block-base-mismatch comment adds the retarget suggestion), then applies the
# `manual-merge` label to the issue so the run-queue frees the slot on its next
# poll. Never flips lifecycle labels or closes the issue. The label is
# fail-open: a gh error only costs the queue its per-agent timeout.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-block-merge.sh <N>:<reason>...

One arg per blocked issue, e.g. `fullsend-block-merge.sh 12:block-ci 14:block-base-mismatch`.
The PR is re-derived from the issue's worktree (fail-closed); with no PR the
comment is skipped and the label still applied. Prints ONE line per issue:
  BLOCK: issue=#<N> pr=#<P> reason=<token> comment=<posted|skipped|failed> label=<applied|failed>
Exit 0 always.
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH, PIPELINE_PROJECT_ROOT, PIPELINE_WORKTREE_PREFIX.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
# shellcheck source=scripts/_fullsend-resolve-pr.sh
source "$SELF_DIR/_fullsend-resolve-pr.sh"

for ARG in "$@"; do
  ISSUE="${ARG%%:*}"
  REASON="${ARG#*:}"
  [ "$REASON" != "$ARG" ] || REASON="unknown"
  fullsend_resolve_pr "$ISSUE"
  if [ -z "$PR_NUM" ]; then
    COMMENT=skipped
  elif [ "$REASON" = "block-base-mismatch" ]; then
    if gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" \
      --body "Auto-merge skipped: block-base-mismatch — PR baseRefName diverges from \$PIPELINE_BASE_BRANCH ($PIPELINE_BASE_BRANCH).

Run \`\$CLAUDE_PLUGIN_ROOT/scripts/retarget-pr.sh $PR_NUM $PIPELINE_BASE_BRANCH\` to retarget (or \`gh pr edit $PR_NUM --base $PIPELINE_BASE_BRANCH\` if retarget-pr.sh is unavailable)." >/dev/null; then
      COMMENT=posted
    else
      COMMENT=failed
    fi
  else
    if gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" \
      --body "Auto-merge skipped: ${REASON}. Run \`gh pr merge\` manually." >/dev/null; then
      COMMENT=posted
    else
      COMMENT=failed
    fi
  fi
  if gh issue edit "$ISSUE" --repo "$PIPELINE_REPO" --add-label "manual-merge" >/dev/null 2>&1; then
    LABEL=applied
  else
    LABEL=failed
  fi
  echo "BLOCK: issue=#$ISSUE pr=#${PR_NUM:-none} reason=$REASON comment=$COMMENT label=$LABEL"
done
exit 0
