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
REBASE=needed unless the PR is MERGEABLE + CLEAN|UNSTABLE and no file changed
on this branch also changed on origin/<base> since the merge-base.
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH.
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

VIEW=$(gh pr view "$PR" --repo "${PIPELINE_REPO:-}" --json mergeable,mergeStateStatus)
MERGEABLE=$(printf '%s' "$VIEW" | jq -r '.mergeable // "UNKNOWN"')
MERGE_STATE=$(printf '%s' "$VIEW" | jq -r '.mergeStateStatus // "UNKNOWN"')

git fetch -q origin "$BASE"
OVERLAP=$(comm -12 \
  <(git diff --name-only "origin/$BASE...HEAD" | sort -u) \
  <(git diff --name-only "HEAD...origin/$BASE" | sort -u) | paste -sd, -)
[ -n "$OVERLAP" ] || OVERLAP=none

REBASE=needed
case "$MERGEABLE:$MERGE_STATE" in
  MERGEABLE:CLEAN|MERGEABLE:UNSTABLE) [ "$OVERLAP" = none ] && REBASE=skip ;;
esac
echo "MERGEABLE=$MERGEABLE MERGE_STATE=$MERGE_STATE OVERLAP=$OVERLAP REBASE=$REBASE"
