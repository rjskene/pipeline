#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
grep -q "CI-fix mode"             skills/execute-issue-plan/SKILL.md || { echo "execute-issue-plan missing CI-fix mode section"; exit 1; }
grep -q "PIPELINE_CI_FIX_CONTEXT" skills/execute-issue-plan/SKILL.md || { echo "execute-issue-plan missing PIPELINE_CI_FIX_CONTEXT ref"; exit 1; }
grep -q "6b. CI-fix loop"         skills/run/SKILL.md                || { echo "run skill missing step 6b"; exit 1; }
grep -q "PIPELINE_CI_FIX_LOOP_ENABLED" skills/run/SKILL.md           || { echo "run skill missing config gate ref"; exit 1; }
echo "ok"
