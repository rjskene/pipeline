#!/usr/bin/env bash
set -euo pipefail

# check-post-plan-freshness.sh — guard against executing a stale plan
#
# Detects when the base branch has drifted far ahead of the worktree's base,
# or when the plan is old, and tells the operator to rebase + re-plan.
#
# Usage:
#   check-post-plan-freshness.sh --base <branch> --worktree-base <sha> \
#     [--plan-epoch <unix-ts>] [--commit-threshold N] [--age-threshold-days D] \
#     [--repo <owner/repo>] [--worktree <path>]
#
# Exit codes:
#   0  FRESH  — both signals within thresholds
#   2  bad args / missing required --base / unresolvable base ref
#   3  STALE  — commit drift or plan age strictly greater than threshold

usage() {
  echo "USAGE: check-post-plan-freshness.sh --base <branch> --worktree-base <sha> [--plan-epoch <unix-ts>] [--commit-threshold N] [--age-threshold-days D] [--repo <owner/repo>] [--worktree <path>]" >&2
  exit 2
}

err() {
  echo "ERROR: $1" >&2
  exit 2
}

BASE=""
WORKTREE_BASE=""
PLAN_EPOCH=""
COMMIT_THRESHOLD=40
AGE_THRESHOLD_DAYS=14
REPO=""
WORKTREE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --worktree-base) WORKTREE_BASE="${2:-}"; shift 2 ;;
    --plan-epoch) PLAN_EPOCH="${2:-}"; shift 2 ;;
    --commit-threshold) COMMIT_THRESHOLD="${2:-}"; shift 2 ;;
    --age-threshold-days) AGE_THRESHOLD_DAYS="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) err "unknown argument: $1" ;;
  esac
done

[[ -n "$BASE" ]] || usage

# Resolve worktree path for remediation hints.
if [[ -z "$WORKTREE" ]]; then
  WORKTREE="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
fi

# Fetch the base only when a remote repo is supplied; otherwise treat --base as
# a local ref (keeps tests hermetic).
if [[ -n "$REPO" ]]; then
  git fetch origin "$BASE" >/dev/null 2>&1 || true
fi

# Resolve the live base tip.
if ! LIVE_BASE_TIP="$(git rev-parse "$BASE" 2>/dev/null)"; then
  err "cannot resolve base ref: $BASE"
fi

# Derive worktree-base when omitted.
if [[ -z "$WORKTREE_BASE" ]]; then
  if ! WORKTREE_BASE="$(git merge-base HEAD "$BASE" 2>/dev/null)"; then
    err "cannot derive worktree-base via merge-base HEAD $BASE"
  fi
fi

# Commit drift: how many commits the base tip is ahead of the worktree base.
if ! DRIFT="$(git rev-list --count "${WORKTREE_BASE}..${LIVE_BASE_TIP}" 2>/dev/null)"; then
  err "cannot compute commit drift ${WORKTREE_BASE}..${LIVE_BASE_TIP}"
fi

# Plan age in whole days (only when --plan-epoch supplied).
AGE_DAYS=0
if [[ -n "$PLAN_EPOCH" ]]; then
  NOW="${PIPELINE_NOW_EPOCH:-$(date +%s)}"
  AGE_DAYS=$(( (NOW - PLAN_EPOCH) / 86400 ))
fi

DRIFT_STALE=0
AGE_STALE=0
[[ "$DRIFT" -gt "$COMMIT_THRESHOLD" ]] && DRIFT_STALE=1
if [[ -n "$PLAN_EPOCH" && "$AGE_DAYS" -gt "$AGE_THRESHOLD_DAYS" ]]; then
  AGE_STALE=1
fi

if [[ "$DRIFT_STALE" -eq 1 || "$AGE_STALE" -eq 1 ]]; then
  cat <<EOF
STALE: base drift ${DRIFT} commits, plan age ${AGE_DAYS}d — exceeds thresholds (drift>${COMMIT_THRESHOLD} or age>${AGE_THRESHOLD_DAYS}d).

Remediation:
  git -C ${WORKTREE} fetch origin ${BASE}
  git -C ${WORKTREE} rebase origin/${BASE}
  then re-run /pipeline:execute-issue-plan <N>.
EOF
  exit 3
fi

echo "FRESH: base drift ${DRIFT} commits, plan age ${AGE_DAYS}d — within thresholds."
exit 0
