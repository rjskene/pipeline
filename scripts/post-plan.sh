#!/bin/bash
# Atomic post helper for plan-issue. Posts the draft, labels plan-pending,
# and verifies both side-effects. Retries each sub-step once on failure.
set -euo pipefail

ISSUE="${1:?usage: post-plan.sh <issue> <draft-file>}"
DRAFT="${2:?usage: post-plan.sh <issue> <draft-file>}"
REPO="${PIPELINE_REPO:?PIPELINE_REPO must be set (source pipeline.config)}"

[ -f "$DRAFT" ] || { echo "post-plan: draft not found: $DRAFT" >&2; exit 1; }
grep -q '## Implementation Plan' "$DRAFT" || {
  echo "post-plan: draft $DRAFT missing '## Implementation Plan' header" >&2
  exit 1
}

retry_once() {
  local label="$1"; shift
  "$@" && return 0
  echo "post-plan: $label failed once, retrying..." >&2
  "$@" && return 0
  echo "post-plan: $label failed twice; draft preserved at $DRAFT" >&2
  return 1
}

# 1) comment
retry_once "gh issue comment" \
  gh issue comment "$ISSUE" --repo "$REPO" --body-file "$DRAFT" \
  || exit 1

# 2) verify comment present
verify_comment() {
  local n
  n=$(gh issue view "$ISSUE" --repo "$REPO" --json comments \
    --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | length')
  [ "${n:-0}" -ge 1 ]
}
retry_once "verify comment" verify_comment || {
  echo "post-plan: no '## Implementation Plan' comment found on issue #$ISSUE after posting; draft preserved at $DRAFT" >&2
  exit 1
}

# 3) label
retry_once "gh issue edit --add-label" \
  gh issue edit "$ISSUE" --repo "$REPO" --add-label plan-pending \
  || exit 1

# 4) verify label present
verify_label() {
  gh issue view "$ISSUE" --repo "$REPO" --json labels \
    --jq '.labels[].name' | grep -qx plan-pending
}
retry_once "verify plan-pending label" verify_label || {
  echo "post-plan: plan-pending label not present on issue #$ISSUE after edit; draft preserved at $DRAFT" >&2
  exit 1
}

echo "post-plan: posted plan + labeled plan-pending on issue #$ISSUE"
