#!/usr/bin/env bash
# plan-issue-context.sh — plan-issue Step 3a/4a inputs in one call: the issue's
# labels, whether the root-cause diagnosis gate fires, and whether a trusted
# `## Root-Cause Diagnosis` comment is fresh enough to consume.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: plan-issue-context.sh <N> [--debug-first]

Prints:
  LABELS=<comma-separated label names>
  DEBUG_FIRST=true|false        true when --debug-first is passed OR the issue carries needs-debug
  DIAGNOSIS=fresh|stale|absent  latest trusted `## Root-Cause Diagnosis`; fresh when
                                its createdAt >= issue.updatedAt (consume it; do not re-diagnose)
Env: PIPELINE_REPO (required).
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; ""|-*) usage >&2; exit 2 ;; esac
N="$1"; shift
DEBUG_FIRST=false
for a in "$@"; do [ "$a" = "--debug-first" ] && DEBUG_FIRST=true; done

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

LABELS=$(gh issue view "$N" --repo "${PIPELINE_REPO:-}" --json labels --jq '.labels[].name')
if printf '%s\n' "$LABELS" | grep -qx "needs-debug"; then DEBUG_FIRST=true; fi

DIAGNOSIS=absent
DIAG_CREATED=$(bash "$SELF_DIR/filter-trusted-comments.sh" --json "$N" 2>/dev/null \
  | jq -r 'last(.comments[] | select(.body | contains("## Root-Cause Diagnosis")) | .createdAt) // empty')
if [ -n "$DIAG_CREATED" ]; then
  ISSUE_UPDATED=$(gh issue view "$N" --repo "${PIPELINE_REPO:-}" --json updatedAt --jq '.updatedAt')
  # Lexicographic compare is correct for ISO-8601 Z timestamps.
  if [[ "$DIAG_CREATED" > "$ISSUE_UPDATED" || "$DIAG_CREATED" == "$ISSUE_UPDATED" ]]; then DIAGNOSIS=fresh; else DIAGNOSIS=stale; fi
fi

echo "LABELS=$(printf '%s\n' "$LABELS" | grep -v '^$' | paste -sd, -)"
echo "DEBUG_FIRST=$DEBUG_FIRST"
echo "DIAGNOSIS=$DIAGNOSIS"
exit 0
