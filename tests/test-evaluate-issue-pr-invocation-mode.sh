#!/usr/bin/env bash
set -euo pipefail
SKILL="skills/evaluate-issue-pr/SKILL.md"
grep -q "Invocation mode" "$SKILL" || { echo "FAIL: evaluate-issue-pr missing 'Invocation mode' preamble"; exit 1; }
grep -q "Agent(" "$SKILL" || { echo "FAIL: evaluate-issue-pr preamble does not name Agent(...) dispatch"; exit 1; }
grep -qE "worktree.*absolute path|cd .*<worktree" "$SKILL" || { echo "FAIL: evaluate-issue-pr preamble does not require cd to worktree on Agent dispatch"; exit 1; }
grep -q "MANUAL_MERGE=1" "$SKILL" || { echo "FAIL: evaluate-issue-pr does not document inline MANUAL_MERGE=1 plumbing"; exit 1; }

# Issue #748: PATH B PR-eval moved from the spawn-claude dispatch shape (mode 2)
# to the inline Agent dispatch shape (mode 1), matching run/SKILL.md Step 6's
# PATH B PR-eval flip — otherwise the inline B PR-eval agent's own skill tells it
# it is a spawned mode-2 dispatch.
MODE1=$(grep -E '^1\. ' "$SKILL" | head -1)
MODE2=$(grep -E '^2\. ' "$SKILL" | head -1)
echo "$MODE1" | grep -qF "Inline" || { echo "FAIL: mode-1 list item is not the inline Agent dispatch shape"; exit 1; }
echo "$MODE2" | grep -qF "spawn-claude.sh" || { echo "FAIL: mode-2 list item is not the spawn-claude dispatch shape"; exit 1; }
echo "$MODE1" | grep -q "PATH B" || { echo "FAIL: mode-1 inline dispatch must list PATH B (#748)"; exit 1; }
echo "$MODE2" | grep -q "PATH C" || { echo "FAIL: mode-2 spawn dispatch must list PATH C"; exit 1; }
echo "$MODE2" | grep -q "PATH B" && { echo "FAIL: mode-2 spawn dispatch must NOT list PATH B (B is inline now, #748)"; exit 1; } || true
echo "PASS: evaluate-issue-pr invocation-mode preamble"
