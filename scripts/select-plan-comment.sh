#!/bin/bash
set -euo pipefail

# select-plan-comment.sh — heading-anchored plan-comment selector (#1240).
#
# THE DEFECT: scripts/plan-waves.sh selected an issue's implementation plan
# with `[.comments[] | select(.body | contains("## Implementation Plan"))]
# | last`. `evaluate-issue-plan` (and `evaluate-issue-pr`) routinely QUOTE
# that heading inside their own `## Plan Evaluation` / `## Evaluation`
# comment — inline code, a fenced block, or a blockquote — and being the
# LATER comment it won the selection, so the wave planner derived
# file-conflict edges from the reviewer's prose instead of the plan.
# Observed live on #1224 / #1225 (inline code) and #1230 (`## Evaluation`).
#
# REUSE PROVENANCE: the fence-toggle + inline-code-span suppression idiom
# (`gsub(/`[^`]*`/, "", line)`) is taken from scripts/parse-tracker-children.sh
# `--fallback-mentions` mode, awk block lines 54-69. The decorated-heading
# tolerance (accepting `## Implementation Plan (round 2)` while rejecting
# `## Implementation Planning`) mirrors the same file's default-mode
# `## Rollout sequence` pattern at line 72 — the same "operators decorate
# headings" hazard, solved the same way.
#
# CONTRACT:
#   stdin  = the `gh issue view --json comments` JSON document
#   stdout = the body of the LAST comment whose FIRST ATX heading IS the
#            plan heading `## Implementation Plan` (trailing decoration
#            tolerated), emitted verbatim; nothing when no comment qualifies
#   exit   = 0 ALWAYS. Callers run under `set -euo pipefail`, so this
#            selector fails OPEN (empty stdout -> caller's pre-existing
#            body-extraction fallback) and never aborts the caller.

JSON=$(cat)

COUNT=$(printf '%s' "$JSON" | jq '.comments | length' 2>/dev/null || echo 0)
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac

SELECTED=""

i=0
while [ "$i" -lt "$COUNT" ]; do
  BODY=$(printf '%s' "$JSON" | jq -r --argjson i "$i" '.comments[$i].body // ""' 2>/dev/null || echo "")
  IS_PLAN=$(printf '%s\n' "$BODY" | awk '
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    in_fence { next }
    /^[[:space:]]*>/ { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^#+[[:space:]]/) {
        if (line ~ /^##[[:space:]]+Implementation Plan([[:space:]]*$|[[:space:]]*[^[:alnum:][:space:]])/)
          print "PLAN"
        exit
      }
    }
  ' || true)
  if [ "$IS_PLAN" = "PLAN" ]; then
    SELECTED="$i"
  fi
  i=$((i + 1))
done

if [ -n "$SELECTED" ]; then
  printf '%s\n' "$(printf '%s' "$JSON" | jq -r --argjson i "$SELECTED" '.comments[$i].body' 2>/dev/null || echo "")"
fi

exit 0
