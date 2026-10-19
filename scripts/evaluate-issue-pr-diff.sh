#!/usr/bin/env bash
# evaluate-issue-pr-diff.sh — evaluate-issue-pr Step 2: resolve the current
# branch's open PR and print its diff, in one call.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: evaluate-issue-pr-diff.sh

Run from the feature worktree. Prints `PR_NUM=<n>` (the open PR whose head is
the current branch), then `gh pr diff <n>`. Exit 1 with
"No open PR found for branch <branch>." when there is none. Env: PIPELINE_REPO.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
PR_NUM=$(gh pr list --repo "${PIPELINE_REPO:-}" --head "$BRANCH" --json number --jq '.[0].number')
if [ -z "$PR_NUM" ] || [ "$PR_NUM" = "null" ]; then
  echo "No open PR found for branch $BRANCH."
  exit 1
fi
echo "PR_NUM=$PR_NUM"
gh pr diff "$PR_NUM" --repo "${PIPELINE_REPO:-}"
