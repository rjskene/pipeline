#!/bin/bash
# Deletes the eval-evidence-<PR> release and its underlying tag.
# Fail-soft: missing-release is treated as success (best-effort cleanup;
# must never block /pipeline:evaluate-issue-pr's auto-merge gate).
#
# Usage: scripts/eval-screenshot-cleanup.sh <pr-number>
set -uo pipefail

PR="${1:-}"
if [ -z "$PR" ]; then
  echo "usage: $(basename "$0") <pr-number>" >&2
  exit 2
fi
: "${PIPELINE_REPO:?PIPELINE_REPO must be set}"

TAG="eval-evidence-${PR}"

if ! gh release view "$TAG" --repo "$PIPELINE_REPO" >/dev/null 2>&1; then
  echo "eval-screenshot-cleanup: release ${TAG} not found — no-op" >&2
  exit 0
fi

if gh release delete "$TAG" --repo "$PIPELINE_REPO" --yes --cleanup-tag >/dev/null 2>&1; then
  echo "eval-screenshot-cleanup: deleted release ${TAG}" >&2
else
  echo "eval-screenshot-cleanup: WARN: failed to delete release ${TAG} (continuing)" >&2
fi

exit 0
