#!/usr/bin/env bash
# fullsend-release-prs.sh — fullsend Step 7b: auto-merge green release-please
# PRs. A silent no-op unless PIPELINE_RELEASE_PR_AUTO_MERGE=true (default off).
# Merge-commit, never squash: release-please walks --first-parent.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-release-prs.sh

When PIPELINE_RELEASE_PR_AUTO_MERGE=true, merges every release PR that
list-release-prs.sh reports ci=pass (`gh pr merge --merge --delete-branch`)
and prints for the rest:
  SKIP: release PR #<P> ci=<state> (auto-merge only on green)
  WARN: failed to merge release PR #<P>
Knob unset/false => no output, no gh call. Exit 0.
Env: PIPELINE_REPO, PIPELINE_RELEASE_PR_AUTO_MERGE, PIPELINE_RELEASE_PR_LABEL.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${PIPELINE_RELEASE_PR_AUTO_MERGE:-false}" = "true" ]; then
  # shellcheck source=scripts/_resolve-config.sh
  [ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    PR_NUM=$(echo "$line" | sed -n 's/^pr=\([0-9][0-9]*\).*/\1/p')
    CI=$(echo "$line" | sed -n 's/.* ci=\([a-z]*\) .*/\1/p')
    if [ "$CI" = "pass" ] && [ -n "$PR_NUM" ]; then
      gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch \
        || echo "WARN: failed to merge release PR #$PR_NUM"
    else
      echo "SKIP: release PR #$PR_NUM ci=$CI (auto-merge only on green)"
    fi
  done <<< "$(PIPELINE_REPO="$PIPELINE_REPO" bash "$SELF_DIR/list-release-prs.sh" 2>/dev/null || true)"
fi
exit 0
