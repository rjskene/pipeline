#!/bin/bash
set -euo pipefail

# select-plan-eval-comment.sh — heading-anchored PLAN-EVALUATION selector (#1435).
#
# WHY: under `PIPELINE_PLAN_GATE=annotate` the plan gate dispatches the
# evaluator ONCE and a `Revise` verdict is carried straight into execute as
# binding amendments — no re-plan, no re-evaluate. `execute-issue-plan` Step 1
# therefore needs the newest trusted `## Plan Evaluation` comment, selected with
# the SAME anchored-heading discipline the plan itself gets (#1240).
#
# REUSE PROVENANCE: a sibling of scripts/select-plan-comment.sh — the awk
# fence-toggle, blockquote skip and inline-code-span suppression
# (`gsub(/`[^`]*`/, "", line)`) are that file's, unchanged; ONLY the heading
# regex differs. Evaluators and PR evaluators routinely quote each other's
# headings inline, fenced, or blockquoted, so the first-ATX-heading anchor is
# what keeps a quote from winning on recency.
#
# TRUST IS NOT THIS SCRIPT'S JOB — deliberately, exactly as in
# select-plan-comment.sh: #545's scripts/filter-trusted-comments.sh --json is
# the SINGLE source of trust truth and runs upstream in the caller's pipeline.
# Do not add author/association logic here.
#
# CONTRACT:
#   stdin  = the (trust-filtered) `gh issue view --json comments` JSON document
#   stdout = the body of the LAST comment whose FIRST ATX heading IS the
#            evaluation heading `## Plan Evaluation` (trailing decoration
#            tolerated), emitted verbatim; nothing when no comment qualifies
#   exit   = 0 ALWAYS. Callers run under `set -euo pipefail`, so this selector
#            fails OPEN (empty stdout -> "no evaluation", caller behaviour
#            unchanged) and never aborts the caller.

JSON=$(cat)

COUNT=$(printf '%s' "$JSON" | jq '.comments | length' 2>/dev/null || echo 0)
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac

SELECTED=""

i=0
while [ "$i" -lt "$COUNT" ]; do
  BODY=$(printf '%s' "$JSON" | jq -r --argjson i "$i" '.comments[$i].body // ""' 2>/dev/null || echo "")
  IS_EVAL=$(printf '%s\n' "$BODY" | awk '
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    in_fence { next }
    /^[[:space:]]*>/ { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^#+[[:space:]]/) {
        if (line ~ /^##[[:space:]]+Plan Evaluation([[:space:]]*$|[[:space:]]*[^[:alnum:][:space:]])/)
          print "EVAL"
        exit
      }
    }
  ' || true)
  if [ "$IS_EVAL" = "EVAL" ]; then
    SELECTED="$i"
  fi
  i=$((i + 1))
done

if [ -n "$SELECTED" ]; then
  printf '%s\n' "$(printf '%s' "$JSON" | jq -r --argjson i "$SELECTED" '.comments[$i].body' 2>/dev/null || echo "")"
fi

exit 0
