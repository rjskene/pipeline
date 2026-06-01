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

# PATH B and PATH C are now SPLIT (issue #748): PATH B dispatches inline via
# Agent(...) (no spawn-claude.sh), PATH C keeps the spawn/run-queue flow.
# Extract a single path bullet block ("- **PATH X**" up to the next "- **PATH")
# from a step window so the B-inline / C-spawn assertions are path-scoped and
# cannot be masked by another path's text elsewhere in the window.
path_block() {
  echo "$1" | awk -v p="$2" '
    $0 ~ "\\*\\*"p"\\*\\*" {grab=1; print; next}
    grab && /^[[:space:]]*-[[:space:]]*\*\*PATH/ {grab=0}
    grab {print}
  '
}

# Step 6 (execution): PATH B inline, PATH C spawn.
STEP6_B=$(path_block "$STEP6" "PATH B")
[ -n "$STEP6_B" ] || { echo "FAIL: Step 6 missing standalone PATH B branch"; exit 1; }
echo "$STEP6_B" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 6 PATH B branch missing inline Agent(subagent_type=...)"; exit 1; }
echo "$STEP6_B" | grep -qF "No spawn-claude.sh" || { echo "FAIL: Step 6 PATH B branch missing 'No spawn-claude.sh' negation"; exit 1; }
STEP6_C=$(path_block "$STEP6" "PATH C")
[ -n "$STEP6_C" ] || { echo "FAIL: Step 6 missing standalone PATH C branch"; exit 1; }
echo "$STEP6_C" | grep -q "spawn-claude.sh" || { echo "FAIL: Step 6 PATH C branch missing spawn-claude.sh"; exit 1; }

# Step 7 (PR evaluation): PATH B inline, PATH C spawn.
STEP7_B=$(path_block "$STEP7" "PATH B")
[ -n "$STEP7_B" ] || { echo "FAIL: Step 7 missing standalone PATH B branch"; exit 1; }
echo "$STEP7_B" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 7 PATH B branch missing inline Agent(subagent_type=...)"; exit 1; }
echo "$STEP7_B" | grep -qF "No spawn-claude.sh" || { echo "FAIL: Step 7 PATH B branch missing 'No spawn-claude.sh' negation"; exit 1; }
STEP7_C=$(path_block "$STEP7" "PATH C")
[ -n "$STEP7_C" ] || { echo "FAIL: Step 7 missing standalone PATH C branch"; exit 1; }
echo "$STEP7_C" | grep -q "spawn-claude.sh" || { echo "FAIL: Step 7 PATH C branch missing spawn-claude.sh"; exit 1; }

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

# Issue #748 drift guard: PATH B is inline now, so no part of the run skill may
# call a PATH B run a "spawned" one (the D escalation backstop used to). This is
# a NOT-spawn-paired assertion in the #748 anti-masking spirit.
grep -qE "spawned PATH B|spawned B run|PATH B.*spawned (worker|run)" "$SKILL" \
  && { echo "FAIL: run SKILL.md still calls a PATH B run 'spawned' (B is inline now, #748)"; exit 1; } || true

echo "PASS: run SKILL.md dispatch routing"
