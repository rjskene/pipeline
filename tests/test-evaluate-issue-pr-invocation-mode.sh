#!/usr/bin/env bash
set -euo pipefail
SKILL="skills/evaluate-issue-pr/SKILL.md"
grep -q "Invocation mode" "$SKILL" || { echo "FAIL: evaluate-issue-pr missing 'Invocation mode' preamble"; exit 1; }
grep -q "Agent(" "$SKILL" || { echo "FAIL: evaluate-issue-pr preamble does not name Agent(...) dispatch"; exit 1; }
grep -qE "worktree.*absolute path|cd .*<worktree" "$SKILL" || { echo "FAIL: evaluate-issue-pr preamble does not require cd to worktree on Agent dispatch"; exit 1; }
grep -q "MANUAL_MERGE=1" "$SKILL" || { echo "FAIL: evaluate-issue-pr does not document inline MANUAL_MERGE=1 plumbing"; exit 1; }
echo "PASS: evaluate-issue-pr invocation-mode preamble"
