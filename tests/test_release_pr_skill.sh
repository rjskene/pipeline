#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Issue #143: full-send autonomous flow moved from skills/run/SKILL.md to
# skills/fullsend/SKILL.md. Task 3 + Task 5 markers live in the run skill
# (housekeeping discovery + interactive propose-action remain there); Task 4
# markers (full-send auto-merge gate / Step 7b) live in the fullsend skill.
SKILL=skills/run/SKILL.md
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
grep -qE 'gh pr merge .* --squash' "$FS_SKILL" || { echo "FAIL: full-send must squash-merge"; exit 1; }
grep -qE 'after step 7|post-step-7|step 7b|7b\.' "$FS_SKILL" || { echo "FAIL: full-send must place merge after step 7"; exit 1; }
echo "PASS test_release_pr_skill (task4)"

# Task 5 markers — interactive propose-action entry for release PRs (in run skill)
grep -qE 'merge release PR|merge the release PR' "$SKILL" || { echo "FAIL: interactive mode must propose merging release PRs"; exit 1; }
awk '/Propose ONE action/,/Wait for user confirmation/' "$SKILL" | grep -q 'release PR' || { echo "FAIL: release PR proposal missing from propose-action block"; exit 1; }
echo "PASS test_release_pr_skill (task5)"
