#!/usr/bin/env bash
set -euo pipefail
SKILL="skills/execute-issue-plan/SKILL.md"
grep -q "Invocation mode" "$SKILL" || { echo "FAIL: execute-issue-plan missing 'Invocation mode' preamble"; exit 1; }
grep -q "Agent(" "$SKILL" || { echo "FAIL: execute-issue-plan preamble does not name Agent(...) dispatch"; exit 1; }
grep -qE "worktree.*absolute path|cd .*<worktree" "$SKILL" || { echo "FAIL: execute-issue-plan preamble does not require cd to worktree on Agent dispatch"; exit 1; }
echo "PASS: execute-issue-plan invocation-mode preamble"
