#!/usr/bin/env bash
set -euo pipefail
SKILL="skills/run/SKILL.md"
[ -f "$SKILL" ] || { echo "FAIL: $SKILL missing"; exit 1; }

STEP6=$(awk '/^[[:space:]]*\*\*For execution \(plan-approved/,/^### Anti-patterns|^8\. \*\*Merge orchestration/' "$SKILL")
STEP7=$(awk '/^[[:space:]]*\*\*For PR evaluation \(pr-open/,/^[[:space:]]*\*\*For execution \(plan-approved/' "$SKILL")

echo "$STEP6" | grep -q "PATH A" || { echo "FAIL: Step 6 missing PATH A branch"; exit 1; }
echo "$STEP6" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 6 PATH A branch missing Agent(subagent_type=...)"; exit 1; }
echo "$STEP7" | grep -q "PATH A" || { echo "FAIL: Step 7 missing PATH A branch"; exit 1; }
echo "$STEP7" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 7 PATH A branch missing Agent(subagent_type=...)"; exit 1; }

echo "$STEP6" | grep -q "spawn-claude.sh" || { echo "FAIL: Step 6 PATH B/C branch missing spawn-claude.sh"; exit 1; }
echo "$STEP7" | grep -q "spawn-claude.sh" || { echo "FAIL: Step 7 PATH B/C branch missing spawn-claude.sh"; exit 1; }

echo "PASS: run SKILL.md dispatch routing"
