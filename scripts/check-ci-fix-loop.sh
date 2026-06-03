#!/usr/bin/env bash
# CI-fix loop decision helper (issue #52).
#
# Issue->PR resolution is DETERMINISTIC per-issue (issue #909): an ordered
# cascade of (1) the issue's own closing PR, (2) the issue's worktree branch
# ref via `git worktree list --porcelain` + `gh pr list --head <ref>`, then
# (3) the open PR whose body references `#<N>`. The off-host case (no local
# worktree) relies on stage 3. This never picks "the latest open PR", so a
# concurrent leg/wave with >=2 open PRs cannot misroute to another issue's PR.
#
# Probes the latest CI run for the PR linked to the given issue, reads
# the current `pipeline.ci-retries: N` counter (encoded as an issue
# comment), and emits exactly one machine-readable line on stdout:
#
#   ACTION=green               ISSUE=<N> PR=<P>
#   ACTION=pending             ISSUE=<N> PR=<P>
#   ACTION=red-retry           ISSUE=<N> PR=<P> RETRIES=<n> BUDGET=<m> LOG=<path>
#   ACTION=red-budget-exhausted ISSUE=<N> PR=<P> RETRIES=<n> BUDGET=<m> LOG=<path>
#   ACTION=skip                ISSUE=<N> REASON=no-pr
#
# Side effects:
#   - On red-retry:            posts a `pipeline.ci-retries: <NEXT>` comment.
#   - On red-budget-exhausted: applies the configured `human` label.
#   - On red-* (either):       writes a tail-truncated failure log to
#                              .claude/logs/ci-fix-<issue>-attempt-<NEXT>.log.

set -euo pipefail

_LOGGING_SH="$(dirname "$0")/_logging.sh"
if [ -f "$_LOGGING_SH" ]; then
  # shellcheck source=./_logging.sh
  . "$_LOGGING_SH"
else
  pipeline_logging_enabled() { [ "${PIPELINE_LOGS_ENABLED:-false}" = "true" ]; }
fi

if [ $# -lt 1 ]; then
  echo "Usage: $0 <issue-number>" >&2
  exit 2
fi
ISSUE="$1"
: "${PIPELINE_REPO:?PIPELINE_REPO must be set}"
: "${PIPELINE_CI_FIX_RETRY_BUDGET:=2}"
: "${PIPELINE_CI_FIX_LOG_LINES:=200}"

# Resolve issue -> PR DETERMINISTICALLY per-issue (issue #909). Ordered
# cascade, first non-empty wins; the helper runs from the orchestrator CWD
# where per-issue worktrees are siblings (`$root/.claude/worktrees/wt-<N>-*`):
#   1. The issue's own closing PR (auto-linked via "Closes #N").
#   2. The issue's worktree branch ref -> `gh pr list --head <ref>` (exact).
#      The full `branch refs/heads/<ref>` line is read VERBATIM from
#      `git worktree list --porcelain` (the same matcher run-queue.sh uses),
#      so any prefix (feature/, fix/, chore/) resolves -- no feature/$SLUG
#      reconstruction.
#   3. Body-reference safety net: the open PR whose body references `#<N>`
#      (the off-host fallback when no local worktree exists).
# This replaces the prior fuzzy `--search "linked:$ISSUE" | .[0]`, which under
# concurrency returned the latest open PR rather than this issue's own PR.
PR_NUM=$(gh issue view "$ISSUE" --repo "$PIPELINE_REPO" \
  --json closedByPullRequestsReferences \
  --jq '.closedByPullRequestsReferences[0].number // empty')

if [ -z "$PR_NUM" ]; then
  : "${PIPELINE_WORKTREE_PREFIX:=wt}"
  BR=$(git worktree list --porcelain 2>/dev/null | awk -v p="${PIPELINE_WORKTREE_PREFIX}-${ISSUE}" '
    /^worktree / { base=$2; sub(/.*\//,"",base); inmatch=(base==p || base ~ "^"p"-") }
    inmatch && /^branch / { sub(/^branch refs\/heads\//,"",$0); print $0; exit }')
  if [ -n "$BR" ]; then
    PR_NUM=$(gh pr list --repo "$PIPELINE_REPO" --head "$BR" \
      --state open --json number --jq '.[0].number // empty' || true)
  fi
fi

if [ -z "$PR_NUM" ]; then
  PR_NUM=$(ISSUE="$ISSUE" gh pr list --repo "$PIPELINE_REPO" --state open \
    --search "$ISSUE in:body" --json number,body \
    --jq '[.[] | select(.body | test("#" + env.ISSUE + "\\b"))] | .[0].number // empty' || true)
fi

if [ -z "$PR_NUM" ]; then
  echo "ACTION=skip ISSUE=$ISSUE REASON=no-pr"
  exit 0
fi

# `gh pr checks --json` exposes `state` (uppercase per-check status:
# SUCCESS / FAILURE / PENDING / SKIPPED / NEUTRAL / CANCELLED / ...) and a
# lowercase `bucket` category — but NOT `conclusion` (that field lives on
# `gh pr view --json statusCheckRollup`). Querying `--json conclusion` here
# errored unconditionally, leaving CONCLUSION empty so no ACTION= was ever
# emitted (issue #876). Map the real `state` field to the same
# green/pending/red verdict: any FAILURE/CANCELLED/TIMED_OUT/ACTION_REQUIRED/
# STARTUP_FAILURE -> red; all SUCCESS/SKIPPED/NEUTRAL -> green; anything else
# (PENDING/EXPECTED) -> pending.
CONCLUSION=$(gh pr checks "$PR_NUM" --repo "$PIPELINE_REPO" \
  --json state --jq \
  '[.[] | .state] | if any(. == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE") then "failure" elif all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL") then "success" else "pending" end')

if [ "$CONCLUSION" = "success" ]; then
  echo "ACTION=green ISSUE=$ISSUE PR=$PR_NUM"
  exit 0
fi
if [ "$CONCLUSION" = "pending" ]; then
  echo "ACTION=pending ISSUE=$ISSUE PR=$PR_NUM"
  exit 0
fi

# CI is red. Read prior retry counter from issue comments.
PRIOR=$(gh issue view "$ISSUE" --repo "$PIPELINE_REPO" --json comments --jq \
  '[.comments[].body | capture("pipeline\\.ci-retries: (?<n>[0-9]+)").n] | map(tonumber) | max // 0')
PRIOR="${PRIOR:-0}"
NEXT=$((PRIOR + 1))

if pipeline_logging_enabled; then
  LOG_DIR="$(pwd)/.claude/logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/ci-fix-${ISSUE}-attempt-${NEXT}.log"
else
  LOG_FILE="$(mktemp -t "pipeline-ci-fix-${ISSUE}-attempt-${NEXT}-XXXX.log")"
fi

RUN_LINK=$(gh pr checks "$PR_NUM" --repo "$PIPELINE_REPO" \
  --json link --jq '[.[] | .link // empty] | .[0]' || true)
RUN_ID=$(printf '%s' "$RUN_LINK" | grep -oE '[0-9]+$' || true)
if [ -n "${RUN_ID:-}" ]; then
  gh run view "$RUN_ID" --repo "$PIPELINE_REPO" --log-failed 2>/dev/null \
    | tail -n "$PIPELINE_CI_FIX_LOG_LINES" > "$LOG_FILE" || true
else
  : > "$LOG_FILE"
fi

if [ "$NEXT" -gt "$PIPELINE_CI_FIX_RETRY_BUDGET" ]; then
  gh issue edit "$ISSUE" --repo "$PIPELINE_REPO" \
    --add-label "${PIPELINE_LABELS_HUMAN:-human}" >/dev/null
  echo "ACTION=red-budget-exhausted ISSUE=$ISSUE PR=$PR_NUM RETRIES=$PRIOR BUDGET=$PIPELINE_CI_FIX_RETRY_BUDGET LOG=$LOG_FILE"
  exit 0
fi

gh issue comment "$ISSUE" --repo "$PIPELINE_REPO" \
  --body "pipeline.ci-retries: $NEXT" >/dev/null
echo "ACTION=red-retry ISSUE=$ISSUE PR=$PR_NUM RETRIES=$NEXT BUDGET=$PIPELINE_CI_FIX_RETRY_BUDGET LOG=$LOG_FILE"
