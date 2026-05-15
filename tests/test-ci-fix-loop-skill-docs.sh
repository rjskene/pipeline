#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
grep -q "CI-fix mode"             skills/execute-issue-plan/SKILL.md || { echo "execute-issue-plan missing CI-fix mode section"; exit 1; }
grep -q "PIPELINE_CI_FIX_CONTEXT" skills/execute-issue-plan/SKILL.md || { echo "execute-issue-plan missing PIPELINE_CI_FIX_CONTEXT ref"; exit 1; }
# Issue #143: Step 6b lives in skills/fullsend/SKILL.md after the run→fullsend extraction.
grep -q "6b. CI-fix loop"              skills/fullsend/SKILL.md      || { echo "fullsend skill missing step 6b"; exit 1; }
grep -q "PIPELINE_CI_FIX_LOOP_ENABLED" skills/fullsend/SKILL.md      || { echo "fullsend skill missing config gate ref"; exit 1; }
echo "ok"
