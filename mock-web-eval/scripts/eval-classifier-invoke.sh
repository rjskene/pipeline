#!/bin/bash
set -euo pipefail

# eval-classifier-invoke.sh (issue #218)
#
# Single source of truth for invoking the consumer-provided pre-spawn
# classifier. Called by run-queue.sh.template and (in inline-evaluate path)
# by the orchestrator from skills/run/SKILL.md Step 7.
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
# REPO_ROOT is resolved as `realpath ../../../mock-web-eval/scripts/eval-classifier-invoke.sh`'s
# three-levels-up dir — i.e. the project root, which is where pipeline.config sits and
# where consumer-configured PIPELINE_EVAL_CLASSIFIER paths are anchored.

ISSUE="${1:-}"
PR="${2:-}"

: "${PIPELINE_EVAL_CLASSIFIER:=}"

if [ -z "$PIPELINE_EVAL_CLASSIFIER" ]; then
  echo "[eval-classifier] classifier-unset" >&2
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
