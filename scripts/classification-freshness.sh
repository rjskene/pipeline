#!/usr/bin/env bash
# classification-freshness.sh — batched freshness probe for `## Classification`
# comments on open issues.
#
# Replaces the per-issue `gh issue view` loop in skills/run/SKILL.md (step 1)
# with a single `gh issue list --json number,updatedAt,comments` round-trip.
# Filters the response down to the supplied issue numbers and labels each
# `fresh|stale` based on the latest `## Classification` comment's createdAt
# vs the issue's updatedAt — the same caching semantics the run skill has
# always used.
#
# Usage:
#   classification-freshness.sh <issue_number> [<issue_number> ...]
#
# Required env:
#   PIPELINE_REPO   GitHub owner/repo (e.g. "rjskene/pipeline")
#
# Emits one TSV line per filtered issue (no header):
#   <number>\t<updatedAt>\t<latest_classification_createdAt_or_empty>\t<fresh|stale>
#
# Empty arg list is a no-op (exit 0, no output). `gh` failures propagate.
# Page limit is 100, matching the existing `gh issue list` call in step 1
# of the run skill; a follow-up ticket would add --paginate if a consumer
# repo ever exceeds 100 simultaneously-open ready issues.

set -euo pipefail

: "${PIPELINE_REPO:?PIPELINE_REPO required}"

[ "$#" -eq 0 ] && exit 0

NUMS_JSON=$(printf '%s\n' "$@" | jq -R . | jq -s .)

gh issue list \
  --repo "$PIPELINE_REPO" \
  --state open \
  --json number,updatedAt,comments \
  --limit 100 \
| jq -r --argjson want "$NUMS_JSON" '
    ($want | map(tonumber)) as $w
    | .[]
    | select(.number as $n | $w | index($n))
    | (([.comments[]? | select(.body | contains("## Classification"))]
          | max_by(.createdAt) | .createdAt) // "") as $class
    | [.number,
       .updatedAt,
       $class,
       (if $class == "" then "stale"
        elif $class > .updatedAt then "fresh"
        else "stale" end)]
    | @tsv'
