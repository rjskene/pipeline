#!/usr/bin/env bash
# execute-issue-plan-fetch-plan.sh — execute-issue-plan Step 1: the trust-gated
# plan fetch, the plan-evaluation amendments and the attachment listing, in one
# call.
#
# Trust is delegated to filter-trusted-comments.sh --json (only OWNER / MEMBER /
# COLLABORATOR comments survive); select-plan-comment.sh then picks the LAST
# trusted comment whose first heading is the plan heading. The sentinel span
# below is pinned by tests/test-stage-plan-fetch-blocks.sh (shared core with
# the evaluate-issue-pr and evaluate-issue-plan fetches; the plan is printed on
# stdout because the executor reads it from there) — edit them together.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-issue-plan-fetch-plan.sh" <N>

Run from the feature worktree. Prints the latest trusted-authored plan comment
for issue <N> on stdout. When the latest trusted plan evaluation carries
`**Verdict:** Revise`, also prints a PLAN-AMENDMENTS line followed by that
evaluation (its Recommendations bind). Then lists .claude/scratch/issue-<N>/
(the attachments the planner saw), or "(no attachments)".
Exit 1 with "No implementation plan found on issue #<N>. Run
/pipeline:plan-issue <N> first." when no trusted plan exists.
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

# BEGIN-PLAN-FETCH
COMMENTS_JSON=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" --json "$N")
PLAN=$(printf '%s' "$COMMENTS_JSON" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/select-plan-comment.sh")
printf '%s\n' "$PLAN"
PLAN_EVAL=$(printf '%s' "$COMMENTS_JSON" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/select-plan-eval-comment.sh")
case "$PLAN_EVAL" in *'**Verdict:** Revise'*) printf 'PLAN-AMENDMENTS\n%s\n' "$PLAN_EVAL" ;; esac
# END-PLAN-FETCH

if [ -z "$PLAN" ] || [ "$PLAN" = "null" ]; then
  echo "No implementation plan found on issue #$N. Run /pipeline:plan-issue $N first."
  exit 1
fi
ls -1 .claude/scratch/issue-"$N"/ 2>/dev/null || echo "(no attachments)"
exit 0
