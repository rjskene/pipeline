#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# pipeline.config is gitignored — prefer it locally, fall back to the
# committed pipeline.config.example so the test also runs in CI.
if [ -f ./pipeline.config ]; then
  # shellcheck disable=SC1091
  source ./pipeline.config
else
  # shellcheck disable=SC1091
  source ./pipeline.config.example
fi

: "${PIPELINE_RELEASE_PR_AUTO_MERGE:?PIPELINE_RELEASE_PR_AUTO_MERGE must be set in pipeline.config}"
: "${PIPELINE_RELEASE_PR_LABEL:?PIPELINE_RELEASE_PR_LABEL must be set in pipeline.config}"
[ "$PIPELINE_RELEASE_PR_AUTO_MERGE" = "false" ] || { echo "FAIL: default must be false (opt-in)"; exit 1; }
[ "$PIPELINE_RELEASE_PR_LABEL" = "autorelease: pending" ] || { echo "FAIL: default label must be 'autorelease: pending'"; exit 1; }
grep -q '^PIPELINE_RELEASE_PR_AUTO_MERGE=' pipeline.config.example || { echo "FAIL: missing in example"; exit 1; }
grep -q '^PIPELINE_RELEASE_PR_LABEL=' pipeline.config.example || { echo "FAIL: missing in example"; exit 1; }
echo "PASS test_release_pr_config"
