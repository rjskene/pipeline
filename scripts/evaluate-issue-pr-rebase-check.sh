#!/usr/bin/env bash
# evaluate-issue-pr-rebase-check.sh — evaluate-issue-pr Step 8: decide whether
# the PR needs a rebase onto the base branch. Read-only: it never rebases.
#
# Mergeability is read HERE (gh pr view --json mergeable,mergeStateStatus), never
# inferred from the preflight's single REASON advisory, and never via the
# rollup (that row would arm hooks/enforce-ci-wait.py). An advanced base alone
# is not a reason to rebase — feature PRs land as merge-commits.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: evaluate-issue-pr-rebase-check.sh <PR>

Run from the feature worktree. Prints one line:
  MERGEABLE=<m> MERGE_STATE=<s> OVERLAP=<files|none> REBASE=needed|skip
REBASE=needed unless the PR is MERGEABLE (any merge state but DIRTY) and no
file changed on this branch also changed on origin/<base> since the merge-base.
An UNKNOWN mergeable is settled by polling first; still UNKNOWN => needed.
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH.
     PIPELINE_MERGEABILITY_POLL_SECS (default 5) — sleep between UNKNOWN reads.
     PIPELINE_MERGEABILITY_POLL_MAX (default 12) — total reads, first included.
     REBASE_CHECK_VIEW_JSON — a {"mergeable":..,"mergeStateStatus":..} object;
     when set it replaces the gh pr view call (fixtures, fullsend-merge-rebase.sh --no-gh).
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
PR="$1"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
BASE="${PIPELINE_BASE_BRANCH:?PIPELINE_BASE_BRANCH unset}"

read_view() {
  VIEW=$(gh pr view "$PR" --repo "${PIPELINE_REPO:-}" --json mergeable,mergeStateStatus)
}
parse_view() {
  MERGEABLE=$(printf '%s' "$VIEW" | jq -r '.mergeable // "UNKNOWN"')
  MERGE_STATE=$(printf '%s' "$VIEW" | jq -r '.mergeStateStatus // "UNKNOWN"')
}

VIEW="${REBASE_CHECK_VIEW_JSON:-}"
if [ -n "$VIEW" ]; then
  parse_view
else
  # GitHub computes mergeability lazily: right after the base advances it
  # answers UNKNOWN. Settle it by polling; still UNKNOWN after the budget
  # falls through to the fail-safe REBASE=needed.
  read_view; parse_view
  reads=1
  while [ "$MERGEABLE" = UNKNOWN ] && [ "$reads" -lt "${PIPELINE_MERGEABILITY_POLL_MAX:-12}" ]; do
    sleep "${PIPELINE_MERGEABILITY_POLL_SECS:-5}"
    read_view; parse_view
    reads=$((reads + 1))
  done
fi

git fetch -q origin "$BASE"
OVERLAP=$(comm -12 \
  <(git diff --name-only "origin/$BASE...HEAD" | sort -u) \
  <(git diff --name-only "HEAD...origin/$BASE" | sort -u) | paste -sd, -)
[ -n "$OVERLAP" ] || OVERLAP=none

REBASE=needed
case "$MERGEABLE:$MERGE_STATE" in
  MERGEABLE:DIRTY) ;;
  MERGEABLE:*) [ "$OVERLAP" = none ] && REBASE=skip ;;
esac
echo "MERGEABLE=$MERGEABLE MERGE_STATE=$MERGE_STATE OVERLAP=$OVERLAP REBASE=$REBASE"
