#!/bin/bash
set -uo pipefail

# mock-web-eval-classifier.sh (issue #231)
#
# Pre-spawn classifier wired via PIPELINE_EVAL_CLASSIFIER in pipeline.config
# and invoked through scripts/eval-classifier-invoke.sh. Emits
# `--container-mode=mock-web-eval` on stdout when the PR touches mock-web/**
# or carries the `web-eval` label; otherwise emits nothing. Non-zero exit on
# gh failure with a stderr diagnostic identifying the failing subcommand.
#
# Usage: mock-web-eval-classifier.sh <issue-number> [<pr-number>]

ISSUE="${1:-}"
PR="${2:-}"

# 1. Derive PR number if missing — silent skip (exit 0) on any derivation failure.
if [ -z "$PR" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    exit 0
  fi
  PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)
  if [ -z "$PR" ] || [ "$PR" = "null" ]; then
    exit 0
  fi
fi

# 2. Fetch diff filenames.
DIFF=$(gh pr diff "$PR" --name-only 2>/dev/null)
DIFF_RC=$?
if [ "$DIFF_RC" -ne 0 ]; then
  echo "mock-web-eval-classifier: gh pr diff failed for PR #$PR (rc=$DIFF_RC)" >&2
  exit "$DIFF_RC"
fi

# 3. Fetch labels.
LABELS=$(gh pr view "$PR" --json labels --jq '.labels[].name' 2>/dev/null)
LABELS_RC=$?
if [ "$LABELS_RC" -ne 0 ]; then
  echo "mock-web-eval-classifier: gh pr view failed for PR #$PR (rc=$LABELS_RC)" >&2
  exit "$LABELS_RC"
fi

# 4. Match: path regex ^mock-web/.+ (case-sensitive) OR exact label `web-eval`.
if printf '%s\n' "$DIFF"   | grep -qE '^mock-web/.+'  \
|| printf '%s\n' "$LABELS" | grep -qx 'web-eval'; then
  echo "--container-mode=mock-web-eval"
fi
exit 0
