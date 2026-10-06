#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
grep -q "CI-fix mode"             skills/execute-issue-plan/SKILL.md || { echo "execute-issue-plan missing CI-fix mode section"; exit 1; }
grep -q "PIPELINE_CI_FIX_CONTEXT" skills/execute-issue-plan/SKILL.md || { echo "execute-issue-plan missing PIPELINE_CI_FIX_CONTEXT ref"; exit 1; }
# #1444: the Step 0b contract BODY was relocated out of the hot-path SKILL.md
# into skills/execute-issue-plan/references/ci-fix-mode.md; the step heading and
# a read pointer stay inline. Pin BOTH halves so the relocation cannot silently
# become a deletion.
grep -q "references/ci-fix-mode.md"   skills/execute-issue-plan/SKILL.md || { echo "execute-issue-plan Step 0b missing the references/ci-fix-mode.md read pointer"; exit 1; }
for needle in 'PIPELINE_CI_FIX_CONTEXT' 'gh pr diff' 'Do NOT call `gh pr create`' 'Do NOT change the `pr-open` label' 'Report the new commit SHA'; do
  grep -qF -- "$needle" skills/execute-issue-plan/references/ci-fix-mode.md \
    || { echo "references/ci-fix-mode.md missing CI-fix contract clause: $needle"; exit 1; }
done
# Issue #143: Step 6b lives in skills/fullsend/SKILL.md after the run→fullsend extraction.
grep -q "6b. CI-fix loop"              skills/fullsend/SKILL.md      || { echo "fullsend skill missing step 6b"; exit 1; }
grep -q "PIPELINE_CI_FIX_LOOP_ENABLED" skills/fullsend/SKILL.md      || { echo "fullsend skill missing config gate ref"; exit 1; }
echo "ok"
