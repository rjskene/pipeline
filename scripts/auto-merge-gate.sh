# shellcheck shell=bash
# Auto-merge greenlight gate helper.
#
# Source this file; it exposes:
#   auto_merge_should_fire <issue> <pr>
#       - prints exactly one reason token, returns 0 only when token == green.
#       - Tokens: green, block-flag, block-label, block-verdict,
#         block-base-mismatch, block-ci, block-mergeable, block-mergestate.
#       - Order: env (MANUAL_MERGE=1) > label (manual-merge on issue) >
#         verdict > base-mismatch > CI rollup > mergeable > mergeStateStatus.
#       - NO_VERDICT=1 skips ONLY the verdict step (for the /pipeline:hotfix
#         --auto-merge emergency lane, which never produces an evaluator
#         verdict — issue #659). Every other check is unchanged, and the
#         MANUAL_MERGE env + manual-merge label opt-outs still precede it.
#       - block-base-mismatch fires when the PR's baseRefName !=
#         $PIPELINE_BASE_BRANCH — eval-time defense-in-depth for the
#         enforce-base-branch hook (see #295, dev/audits/295-root-cause.md).
#   parse_manual_merge_argv <args>...
#       - sets MANUAL_MERGE=1 when --manual-merge appears in argv at any
#         position; prints the remaining args (one per line) to stdout.
#
# Requires: gh (>= 2.0 for mergeStateStatus), jq, $PIPELINE_REPO and
#           $PIPELINE_BASE_BRANCH in env.

auto_merge_should_fire() {
  local issue="$1" pr="$2"

  if ! command -v jq >/dev/null 2>&1; then
    echo "[auto-merge-gate] ERROR: jq is required but not on PATH" >&2
    return 2
  fi

  if [ "${MANUAL_MERGE:-0}" = "1" ]; then
    echo block-flag
    return 1
  fi

  if gh issue view "$issue" --repo "$PIPELINE_REPO" --json labels \
       --jq '.labels[].name' 2>/dev/null | grep -qx manual-merge; then
    echo block-label
    return 1
  fi

  if [ "${NO_VERDICT:-0}" != "1" ]; then
    local verdict
    verdict=$(gh pr view "$pr" --repo "$PIPELINE_REPO" --json comments \
      --jq '[.comments[] | select(.body | contains("## Evaluation"))] | last | .body' \
      2>/dev/null \
      | grep -oE '\*\*Verdict:\*\* (Approved|Flagged[^[:space:]]*|Revise|Reject)' \
      | head -1 | awk '{print $2}')
    if [ "$verdict" != "Approved" ]; then
      echo block-verdict
      return 1
    fi
  fi

  # Defense-in-depth (issue #295): refuse to merge when the PR's baseRefName
  # diverges from $PIPELINE_BASE_BRANCH. The enforce-base-branch PreToolUse
  # hook covers gh pr create + gh pr edit --base at write time, but it has
  # bypassed in production (stale rendered spawn-claude.sh, consumer
  # settings.json shadowing) — see dev/audits/295-root-cause.md. This
  # eval-time check is the load-bearing zero-data-loss gate.
  local base
  base=$(gh pr view "$pr" --repo "$PIPELINE_REPO" --json baseRefName \
    --jq .baseRefName 2>/dev/null)
  if [ -z "$base" ] || [ "$base" != "$PIPELINE_BASE_BRANCH" ]; then
    echo block-base-mismatch
    return 1
  fi

  local rollup mergeable mergestate
  rollup=$(gh pr view "$pr" --repo "$PIPELINE_REPO" \
    --json statusCheckRollup,mergeable,mergeStateStatus 2>/dev/null)
  if ! echo "$rollup" | jq -e '.statusCheckRollup | length == 0 or all(.conclusion == "SUCCESS")' >/dev/null 2>&1; then
    echo block-ci
    return 1
  fi
  mergeable=$(echo "$rollup" | jq -r '.mergeable' 2>/dev/null)
  if [ "$mergeable" != "MERGEABLE" ]; then
    echo block-mergeable
    return 1
  fi
  mergestate=$(echo "$rollup" | jq -r '.mergeStateStatus' 2>/dev/null)
  if [ "$mergestate" != "CLEAN" ]; then
    echo block-mergestate
    return 1
  fi

  echo green
  return 0
}

parse_manual_merge_argv() {
  # Loop-based parser: --manual-merge may appear anywhere in argv.
  # Cannot collide with issue numbers because those are bare integers.
  MANUAL_MERGE="${MANUAL_MERGE:-0}"
  local arg
  for arg in "$@"; do
    case "$arg" in
      --manual-merge) MANUAL_MERGE=1 ;;
      *) printf '%s\n' "$arg" ;;
    esac
  done
}
