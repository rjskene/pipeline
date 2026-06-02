#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Per #857/#762, PIPELINE_RELEASE_PR_AUTO_MERGE was demoted from a live line to
# a commented escape-hatch in pipeline.config.example — its `false` default is
# now single-sourced at the read site (${PIPELINE_RELEASE_PR_AUTO_MERGE:-false}
# in skills/fullsend/SKILL.md). PIPELINE_RELEASE_PR_LABEL is NOT demoted (it has
# no read-site default) and stays a live line.

EXAMPLE="pipeline.config.example"

# (1) RELEASE_PR_LABEL stays a live, sourceable line with the canonical default.
if [ -f ./pipeline.config ]; then
  # shellcheck disable=SC1091
  source ./pipeline.config
else
  # shellcheck disable=SC1091
  source ./"$EXAMPLE"
fi
: "${PIPELINE_RELEASE_PR_LABEL:?PIPELINE_RELEASE_PR_LABEL must be set in pipeline.config}"
[ "$PIPELINE_RELEASE_PR_LABEL" = "autorelease: pending" ] || { echo "FAIL: default label must be 'autorelease: pending'"; exit 1; }

# (2) RELEASE_PR_AUTO_MERGE survives as a discoverable escape-hatch (commented OR
#     live) in the example, carrying the `false` opt-in default.
grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_RELEASE_PR_AUTO_MERGE="?false"?' "$EXAMPLE" \
  || { echo "FAIL: PIPELINE_RELEASE_PR_AUTO_MERGE missing/wrong-default in example"; exit 1; }

# (3) RELEASE_PR_LABEL is present in the example.
grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_RELEASE_PR_LABEL=' "$EXAMPLE" \
  || { echo "FAIL: PIPELINE_RELEASE_PR_LABEL missing in example"; exit 1; }

# (4) The `false` default is single-sourced at the fullsend read site.
grep -qE 'PIPELINE_RELEASE_PR_AUTO_MERGE:-false' skills/fullsend/SKILL.md \
  || { echo "FAIL: read-site default \${PIPELINE_RELEASE_PR_AUTO_MERGE:-false} missing in fullsend SKILL.md"; exit 1; }

echo "PASS test_release_pr_config"
