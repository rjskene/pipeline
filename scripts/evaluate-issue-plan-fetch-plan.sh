#!/usr/bin/env bash
# evaluate-issue-plan-fetch-plan.sh — evaluate-issue-plan Step 1: the issue
# details plus the trust-gated plan fetch, in one call.
#
# Trust is delegated to filter-trusted-comments.sh --json (only OWNER / MEMBER /
# COLLABORATOR comments survive); select-plan-comment.sh then picks the LAST
# trusted comment whose first heading is the plan heading. The sentinel span
# below is pinned by tests/test-stage-plan-fetch-blocks.sh (shared core with
# the evaluate-issue-pr and execute-issue-plan fetches) — edit them together.
# The issue fetch is stage-local, so it sits outside the sentinels.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-plan-fetch-plan.sh" <N>

Prints issue <N> (number, title, body) as one JSON line, then the latest
trusted-authored plan comment. Exit 1 with "No implementation plan found for
issue #<N>." when no trusted plan exists (none posted, or every candidate was
authored by an untrusted account — the stderr audit lists dropped authors).
Env: PIPELINE_REPO, CLAUDE_PLUGIN_ROOT (defaults to this repo).
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
N="$1"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

gh issue view "$N" --repo "$PIPELINE_REPO" --json number,title,body

# BEGIN-PLAN-FETCH
COMMENTS_JSON=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" --json "$N")
PLAN=$(printf '%s' "$COMMENTS_JSON" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/select-plan-comment.sh")
printf '%s\n' "$PLAN"
# END-PLAN-FETCH

if [ -z "$PLAN" ] || [ "$PLAN" = "null" ]; then
  echo "No implementation plan found for issue #$N."
  exit 1
fi
exit 0
