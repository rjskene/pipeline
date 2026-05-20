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

# PATH D (quick-fix): inline dispatch via BARE tdd-implementer subagent,
# explicitly NOT through spawn-claude.sh. Mirrors the A/B/C fixture style:
# the assertion lives inside Step 6's "For execution" window.
echo "$STEP6" | grep -q "PATH D" || { echo "FAIL: Step 6 missing PATH D branch"; exit 1; }
echo "$STEP6" | grep -q "quick-fix" || { echo "FAIL: Step 6 PATH D branch missing quick-fix label reference"; exit 1; }
echo "$STEP6" | grep -qF "Agent(subagent_type='tdd-implementer'" \
  || { echo "FAIL: Step 6 PATH D branch missing BARE Agent(subagent_type='tdd-implementer'"; exit 1; }
# Defensive: the BARE form, not the pipeline:tdd-implementer namespaced form,
# in the PATH D dispatch block.
echo "$STEP6" | grep -qF "pipeline:tdd-implementer" \
  && { echo "FAIL: Step 6 must use BARE tdd-implementer, not pipeline:tdd-implementer"; exit 1; } \
  || true
# PATH D explicitly does NOT use spawn-claude.sh — verify the negation
# phrasing is present.
echo "$STEP6" | grep -qF "No spawn-claude.sh" \
  || { echo "FAIL: Step 6 PATH D branch missing 'No spawn-claude.sh' negation"; exit 1; }

echo "PASS: run SKILL.md dispatch routing"
