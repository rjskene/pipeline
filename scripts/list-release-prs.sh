#!/usr/bin/env bash
# Emit one line per open release-bot PR (default label "autorelease: pending"):
#   pr=<num> ci=<pass|fail|pending> title=<title>
# CI status mapping (statusCheckRollup):
#   all SUCCESS                                  -> pass
#   any FAILURE|ERROR|CANCELLED|TIMED_OUT        -> fail
#   else (in-progress, queued, neutral, empty)   -> pending
set -euo pipefail

# Resolve repo root from this script's location so the helper works whether
# invoked from the plugin cache (${CLAUDE_PLUGIN_ROOT}) or from a dogfood
# checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Prefer the consumer pipeline.config; fall back to the example so the helper
# is usable in fresh checkouts. PIPELINE_REPO / PIPELINE_RELEASE_PR_LABEL may
# also be supplied via the environment.
if [ -f "$REPO_ROOT/pipeline.config" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/pipeline.config"
elif [ -f "$REPO_ROOT/pipeline.config.example" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/pipeline.config.example"
fi

LIMIT="${RELEASE_PR_LIMIT:-5}"

gh pr list --repo "$PIPELINE_REPO" --state open \
  --label "$PIPELINE_RELEASE_PR_LABEL" \
  --limit "$LIMIT" \
  --json number,title,headRefName,statusCheckRollup \
| jq -r '
    .[] |
    . as $pr |
    (
      ($pr.statusCheckRollup // []) as $rollup |
      (
        if ($rollup | length) == 0 then "pending"
        elif any($rollup[]; (.conclusion // .status) | ascii_upcase | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT")) then "fail"
        elif all($rollup[]; (.conclusion // "") | ascii_upcase == "SUCCESS") then "pass"
        else "pending"
        end
      ) as $ci |
      "pr=\($pr.number) ci=\($ci) title=\($pr.title)"
    )
  '
