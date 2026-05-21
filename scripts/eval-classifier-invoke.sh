#!/bin/bash
set -euo pipefail

# eval-classifier-invoke.sh (issue #218, plugin-shipped variant)
#
# Single source of truth for invoking the consumer-provided pre-spawn
# classifier. Called by scripts/run-queue.sh (classify_issue) and
# scripts/spawn-claude.sh (the #238 re-classification block).
#
# Usage: eval-classifier-invoke.sh <issue-number> [<pr-number>]
#
# Contract:
#   $PIPELINE_EVAL_CLASSIFIER unset           -> exit 0, stderr "classifier-unset" marker
#   classifier exit 0 with stdout tokens      -> exit 0, stdout forwarded verbatim
#   classifier exit N with stderr             -> exit N, stderr forwarded
#   $PIPELINE_EVAL_CLASSIFIER set but file
#     missing on disk at REPO_ROOT/<path>     -> exit 3, stderr "classifier-not-found: <abs>"
#
# REPO_ROOT is resolved from PIPELINE_PROJECT_ROOT (set by run-queue.sh /
# spawn-claude.sh, which pass the consumer repo root), falling back to
# $(pwd) when the helper is invoked directly. This anchors consumer-
# relative PIPELINE_EVAL_CLASSIFIER paths at the consumer project root,
# not the plugin install dir.

ISSUE="${1:-}"
PR="${2:-}"

: "${PIPELINE_EVAL_CLASSIFIER:=}"

if [ -z "$PIPELINE_EVAL_CLASSIFIER" ]; then
  echo "[eval-classifier] classifier-unset" >&2
  exit 0
fi

REPO_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
SCRIPT_PATH="${REPO_ROOT}/${PIPELINE_EVAL_CLASSIFIER}"

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "[eval-classifier] classifier-not-found: $SCRIPT_PATH" >&2
  exit 3
fi

# Forward stdout + stderr + exit code verbatim. Disable -e around the inner
# invocation so a non-zero classifier exit reaches our `exit $rc` rather than
# tripping `set -e`.
set +e
bash "$SCRIPT_PATH" "$ISSUE" "$PR"
rc=$?
set -e
exit "$rc"
