#!/usr/bin/env bash
# Emit one deterministic ledger line per OPEN pull request:
#   pr=<num> base=<baseRefName> draft=<true|false> ci=<pass|fail|pending> \
#     review=<approved|changes|none> issue=<N|--> title=<title>
#
# Advisory / read-only feed for /pipeline:status — rendered as the "UNMERGED
# PRs" section by scripts/render-status-table.sh (--open-prs). Mirror of
# scripts/list-release-prs.sh. Issue #1168.
#
# Field mappings:
#   ci     (statusCheckRollup):
#     all SUCCESS                                  -> pass
#     any FAILURE|ERROR|CANCELLED|TIMED_OUT        -> fail
#     else (in-progress, queued, neutral, empty)   -> pending
#   review (reviewDecision):
#     APPROVED          -> approved
#     CHANGES_REQUESTED -> changes
#     null/empty/other  -> none
#   issue  (linked issue — resolved by resolve_issue_ref, precedence below):
#     1) headRefName branch slug: a trailing `-<N>` (e.g. feature/foo-1168)
#     2) body closing keyword: `Closes #N` / `Fixes #N` / `Resolves #N`
#     3) else `--`
#     (GraphQL closingIssuesReferences is the intended v2 precedent-0 source;
#      the fallback resolver degrades to `--`, never a wrong link, per #1168.)
#
# CRLF discipline (#1165): the single jq->shell boundary is piped through
# `tr -d '\r'` so a Git-for-Windows (msvcrt) jq that appends \r\n cannot
# poison PR numbers or key lookups downstream.
set -euo pipefail

# Resolve repo root from this script's location so the helper works whether
# invoked from the plugin cache (${CLAUDE_PLUGIN_ROOT}) or a dogfood checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Prefer the consumer pipeline.config; fall back to the example so the helper
# is usable in fresh checkouts. PIPELINE_REPO may also come from the env.
if [ -f "$REPO_ROOT/pipeline.config" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/pipeline.config"
elif [ -f "$REPO_ROOT/pipeline.config.example" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/pipeline.config.example"
fi

LIMIT="${OPEN_PR_LIMIT:-30}"

# resolve_issue_ref <headRefName> <body_issue_num>
# Isolated + independently testable linked-issue resolver. Precedence:
# branch-slug trailing -<N> → pre-extracted body Closes/Fixes #<N> → "--".
# (GraphQL closingIssuesReferences would slot in ahead of both when added.)
resolve_issue_ref() {
  local headref="$1" body_issue="$2"
  if [[ "$headref" =~ -([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [ -n "$body_issue" ]; then
    printf '%s' "$body_issue"
    return 0
  fi
  printf '%s' "--"
}

gh pr list --repo "$PIPELINE_REPO" --state open \
  --limit "$LIMIT" \
  --json number,title,baseRefName,isDraft,reviewDecision,statusCheckRollup,headRefName,body \
| jq -r '
    .[] |
    . as $pr |
    (
      ($pr.statusCheckRollup // []) as $rollup |
      (
        if ($rollup | length) == 0 then "pending"
        elif any($rollup[]; (.conclusion // .status) | ascii_upcase | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT")) then "fail"
        elif all($rollup[]; (.conclusion // "") | ascii_upcase == "SUCCESS") then "pass"
        else "pending"
        end
      ) as $ci |
      (
        ($pr.reviewDecision // "") as $rd |
        if   $rd == "APPROVED"          then "approved"
        elif $rd == "CHANGES_REQUESTED" then "changes"
        else "none" end
      ) as $review |
      (
        [ ($pr.body // "")
          | scan("\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[ \t]+#([0-9]+)"; "i") ]
        | flatten | first // ""
      ) as $body_issue |
      # Unit-separator () delimited handoff to the shell resolver. A NON
      # whitespace delimiter is required: with a tab/space IFS, `read` collapses
      # runs of the delimiter, so an EMPTY body_issue field would swallow title.
      # Title is last and has any stray  scrubbed so it cannot corrupt
      # field splitting.
      "\($pr.number)\($pr.baseRefName)\($pr.isDraft)\($ci)\($review)\($pr.headRefName)\($body_issue)\($pr.title | gsub(""; " "))"
    )
  ' \
| tr -d '\r' \
| while IFS=$'\x1f' read -r num base draft ci review headref body_issue title; do
    [ -n "$num" ] || continue
    issue=$(resolve_issue_ref "$headref" "$body_issue")
    printf 'pr=%s base=%s draft=%s ci=%s review=%s issue=%s title=%s\n' \
      "$num" "$base" "$draft" "$ci" "$review" "$issue" "$title"
  done
