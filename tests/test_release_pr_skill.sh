#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SKILL=skills/run/SKILL.md
[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found"; exit 1; }

# Task 3 markers
grep -q 'scripts/list-release-prs.sh' "$SKILL" || { echo "FAIL: skill must invoke list-release-prs.sh"; exit 1; }
grep -q 'Release PRs' "$SKILL" || { echo "FAIL: skill must label the row group 'Release PRs'"; exit 1; }
grep -q 'release-pending' "$SKILL" || { echo "FAIL: skill must use 'release-pending' stage value"; exit 1; }
grep -q 'autorelease: pending' "$SKILL" || { echo "FAIL: skill must reference 'autorelease: pending' (config-driven)"; exit 1; }
echo "PASS test_release_pr_skill (task3)"

# Task 4 markers — full-send auto-merge gate
grep -q 'PIPELINE_RELEASE_PR_AUTO_MERGE' "$SKILL" || { echo "FAIL: full-send must gate on PIPELINE_RELEASE_PR_AUTO_MERGE"; exit 1; }
grep -qE 'gh pr merge .* --squash' "$SKILL" || { echo "FAIL: full-send must squash-merge"; exit 1; }
grep -qE 'after step 7|post-step-7|step 7b|7b\.' "$SKILL" || { echo "FAIL: full-send must place merge after step 7"; exit 1; }
echo "PASS test_release_pr_skill (task4)"
