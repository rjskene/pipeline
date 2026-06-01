#!/usr/bin/env bash
set -euo pipefail
SKILL="skills/execute-issue-plan/SKILL.md"
grep -q "Invocation mode" "$SKILL" || { echo "FAIL: execute-issue-plan missing 'Invocation mode' preamble"; exit 1; }
grep -q "Agent(" "$SKILL" || { echo "FAIL: execute-issue-plan preamble does not name Agent(...) dispatch"; exit 1; }
grep -qE "worktree.*absolute path|cd .*<worktree" "$SKILL" || { echo "FAIL: execute-issue-plan preamble does not require cd to worktree on Agent dispatch"; exit 1; }

# Issue #748: PATH B moved from spawn dispatch (mode 2) to inline Agent (mode 1).
# Mode 1 "Used by" must name PATH B; mode 2 spawn row must name only PATH C
# (not PATH B). Assertions are scoped to the specific table row.
MODE1=$(grep -E '^\| 1 \|' "$SKILL")
MODE2=$(grep -E '^\| 2 \|' "$SKILL")
echo "$MODE1" | grep -q "PATH B" || { echo "FAIL: mode-1 inline row must list PATH B"; exit 1; }
echo "$MODE2" | grep -q "PATH C" || { echo "FAIL: mode-2 spawn row must list PATH C"; exit 1; }
echo "$MODE2" | grep -q "PATH B" && { echo "FAIL: mode-2 spawn row must NOT list PATH B (B is inline now)"; exit 1; } || true
echo "PASS: execute-issue-plan invocation-mode preamble"
