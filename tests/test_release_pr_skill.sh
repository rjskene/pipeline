#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Issue #143: full-send autonomous flow moved from the old /pipeline:run skill
# to skills/fullsend/SKILL.md. Task 4 markers (full-send auto-merge gate /
# Step 7b) live in the fullsend skill.
#
# #763: the run→status rename moved the housekeeping release-PR DISCOVERY markers
# (Task 3) into the read-only skills/status/SKILL.md, and REMOVED the Task-5
# interactive "propose merging the release PR" action entirely — /pipeline:status
# proposes nothing, and autonomous merge of release PRs lives in fullsend's
# Step 7b (already covered by the Task-4 markers).
SKILL=skills/status/SKILL.md
FS_SKILL=skills/fullsend/SKILL.md
[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found"; exit 1; }
[ -f "$FS_SKILL" ] || { echo "FAIL: $FS_SKILL not found"; exit 1; }

# Task 3 markers
grep -q 'scripts/list-release-prs.sh' "$SKILL" || { echo "FAIL: skill must invoke list-release-prs.sh"; exit 1; }
grep -q 'Release PRs' "$SKILL" || { echo "FAIL: skill must label the row group 'Release PRs'"; exit 1; }
grep -q 'release-pending' "$SKILL" || { echo "FAIL: skill must use 'release-pending' stage value"; exit 1; }
grep -q 'autorelease: pending' "$SKILL" || { echo "FAIL: skill must reference 'autorelease: pending' (config-driven)"; exit 1; }
echo "PASS test_release_pr_skill (task3)"

# Task 4 markers — full-send auto-merge gate (now in fullsend skill)
grep -q 'PIPELINE_RELEASE_PR_AUTO_MERGE' "$FS_SKILL" || { echo "FAIL: full-send must gate on PIPELINE_RELEASE_PR_AUTO_MERGE"; exit 1; }
grep -qE 'gh pr merge .* --merge' "$FS_SKILL" || { echo "FAIL: full-send must merge-commit"; exit 1; }
grep -qE 'after step 7|post-step-7|step 7b|7b\.' "$FS_SKILL" || { echo "FAIL: full-send must place merge after step 7"; exit 1; }
echo "PASS test_release_pr_skill (task4)"

# Task 5 markers DELETED for #763: the interactive "propose merging the release
# PR" action was removed when /pipeline:run became the read-only /pipeline:status
# survey (status proposes no actions). Autonomous release-PR merge now lives in
# fullsend's Step 7b, which is already covered by the Task-4 markers above.
# Verified obsolete: neither "merge release PR" nor a "Propose ONE action" block
# exists in skills/status/SKILL.md.
