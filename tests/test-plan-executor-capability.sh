#!/bin/bash
set -euo pipefail

# Executor-capability guard (#1225).
#
# Contract under test: a plan task must NEVER mandate a capability the
# assigned executor lacks, and the leaf executor must refuse LOUDLY rather
# than silently substituting a manual approximation.
#
# The concrete defect: `skills/plan-issue/SKILL.md` emitted an unattributed
# closing task ("Task N: PATH A/B/C — invoke `superpowers:requesting-code-review`")
# while `agents/tdd-implementer.md` declares `tools: Read, Write, Edit, Bash,
# Grep, Glob` — no `Skill`, no `Agent`. Any PATH C `target=<dir>` leaf (or
# PATH D task) that inherits that directive is structurally unexecutable.
#
# Shape mirrors tests/test-plan-issue-path-tasks.sh (counters + summary rule).
#
# ---------------------------------------------------------------------------
# Assertion ledger at the `[split-role-red]` marker commit
# ---------------------------------------------------------------------------
#   RED   : A1 A2 A3 A4 A6 A7 A8 A9 A10 — the target prose does not exist yet.
#   GREEN : A5 ONLY. A5 is the Direction-3 regression guard: it asserts the
#           `tdd-implementer` `tools:` line still EXCLUDES `Agent` and `Skill`.
#           That is already true at HEAD *by design* and must stay true
#           forever — its job is to fail if someone later grants the leaf a
#           `Skill` tool. It is NOT vacuous: its negative control (appending
#           `, Skill` to the tools line) flips it to FAIL. Do NOT "fix" A5.
#
# A3 anchoring note: the bare substring `PATH A/B` is ALSO a substring of
# `PATH A/B/C`, so an unanchored `PATH A/B` grep would pass at HEAD and be
# vacuous. A3 therefore pins the literal `Task N: PATH A/B —` (space + EM
# DASH), which is genuinely absent at HEAD.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PLAN="$SCRIPT_DIR/../skills/plan-issue/SKILL.md"
AGENT="$SCRIPT_DIR/../agents/tdd-implementer.md"
EXEC="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"
FS="$SCRIPT_DIR/../skills/fullsend/SKILL.md"
DOC="$SCRIPT_DIR/../docs/superpowers-integration.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$PLAN" "$AGENT" "$EXEC" "$FS" "$DOC"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

# --- Extractors -------------------------------------------------------------
# Each is scoped so an incidental match elsewhere in the file cannot satisfy
# an assertion. `|| true` keeps a zero-match extraction from aborting under
# `set -euo pipefail` — an empty extraction must surface as a FAILING
# assertion with a readable message, not as a silent script abort.

# The canonical closing-task bullet. `- Task N:` is unique in the file.
TASKN=$(grep -F -- '- Task N:' "$PLAN" | head -1 || true)

# The planner-side rule paragraph: heading phrase line through the first
# blank line (the rule is authored as a SINGLE paragraph).
RULEPARA=$(awk '/Executor-capability rule/{i=1} i && NF==0{i=0} i' "$PLAN" || true)

# Agent frontmatter / body split — same split as test-tdd-implementer-agent.sh.
AGENT_FM=$(awk '/^---$/{c++; next} c==1' "$AGENT" || true)
AGENT_BODY=$(awk '/^---$/{c++; next} c>=2' "$AGENT" || true)

# The `## Forbidden` section BODY only (stops at the next `## ` heading).
FORBIDDEN=$(awk '/^## Forbidden/{i=1;next} i && /^## /{i=0} i' "$AGENT" || true)

# execute-issue-plan Step 8, bounded by the Step 9 heading.
STEP8=$(awk '/^8\. \*\*Pre-PR code review loop/{i=1} i; /^9\. \*\*Open a pull request/{i=0}' "$EXEC" || true)

# The fullsend PATH C execute-routing bullet (the PATH C orchestrator runbook).
FSC=$(grep -F -- '- **PATH C** (`multi-task`): dispatch inline by DEFAULT' "$FS" | head -1 || true)

# The superpowers-integration row for plan-issue -> requesting-code-review.
DOCROW=$(grep -F '| `plan-issue` |' "$DOC" | grep -F 'requesting-code-review' || true)

# --- A1: planner-side executor-capability rule exists ------------------------
echo "A1: plan-issue states the executor-capability rule"
inc
if [ -z "$RULEPARA" ]; then
  fail_msg "no 'Executor-capability rule' paragraph in skills/plan-issue/SKILL.md"
elif grep -qF "Executor-capability rule" "$PLAN" \
   && printf '%s' "$RULEPARA" | grep -qF "tdd-implementer" \
   && printf '%s' "$RULEPARA" | grep -qF "Skill" \
   && printf '%s' "$RULEPARA" | grep -qF "Agent"; then
  pass_msg "rule paragraph names tdd-implementer and both missing tools (Skill, Agent)"
else
  fail_msg "rule paragraph must name 'tdd-implementer', 'Skill' and 'Agent'"
fi

# --- A2: the un-scoped PATH A/B/C directive is gone --------------------------
echo "A2: the unattributed 'Task N: PATH A/B/C' directive is removed"
inc
if ! grep -qF "Task N: PATH A/B/C" "$PLAN"; then
  pass_msg "no unattributed PATH A/B/C closing-task directive remains"
else
  fail_msg "'Task N: PATH A/B/C' still present — a PATH C leaf can inherit a Skill-mandating task"
fi

# --- A3: PATH A/B closing task is role-attributed ---------------------------
# Anchored on the EM DASH form; bare 'PATH A/B' is a substring of 'PATH A/B/C'
# and would make this assertion vacuous.
echo "A3: closing task is scoped to PATH A/B and still names the review skill"
inc
if [ -z "$TASKN" ]; then
  fail_msg "no '- Task N:' bullet found in skills/plan-issue/SKILL.md"
elif grep -qF -- "Task N: PATH A/B —" "$PLAN" \
   && printf '%s' "$TASKN" | grep -qF -- "Task N: PATH A/B —" \
   && printf '%s' "$TASKN" | grep -qF "superpowers:requesting-code-review"; then
  pass_msg "Task N bullet is anchored to 'Task N: PATH A/B —' and names requesting-code-review"
else
  fail_msg "Task N bullet must carry the literal 'Task N: PATH A/B —' (space + em dash) and 'superpowers:requesting-code-review'"
fi

# --- A4: closing task assigns PATH C ownership to the orchestrator ----------
echo "A4: closing task assigns PATH C ownership away from the leaf executor"
inc
if [ -z "$TASKN" ]; then
  fail_msg "no '- Task N:' bullet found in skills/plan-issue/SKILL.md"
elif printf '%s' "$TASKN" | grep -qF "PATH C" \
   && printf '%s' "$TASKN" | grep -qi "orchestrator" \
   && printf '%s' "$TASKN" | grep -qi "leaf"; then
  pass_msg "Task N bullet names PATH C, the orchestrator owner, and the leaf exclusion"
else
  fail_msg "Task N bullet must name the literal 'PATH C', an 'orchestrator' owner, and the 'leaf' exclusion"
fi

# --- A5: STANDING-GREEN regression guard (Direction 3 excluded) -------------
# INTENTIONALLY GREEN AT HEAD. Do NOT try to make this fail. It exists to trip
# if the leaf executor is ever granted `Skill`/`Agent` (issue #1225 Direction 3,
# explicitly rejected). Negative control: `tools: ..., Glob, Skill` => FAIL.
echo "A5: tdd-implementer tools still EXCLUDE Agent and Skill (standing-green guard)"
inc
TOOLS_LINE=$(printf '%s\n' "$AGENT_FM" | grep -E '^tools:' | head -1 || true)
if [ -z "$TOOLS_LINE" ]; then
  fail_msg "no 'tools:' line in agents/tdd-implementer.md frontmatter"
else
  BAD=""
  for t in Agent Skill; do
    if printf '%s' "$TOOLS_LINE" | grep -qE "(^|[^A-Za-z])${t}([^A-Za-z]|$)"; then
      BAD="$BAD $t"
    fi
  done
  if [ -z "$BAD" ]; then
    pass_msg "leaf executor toolset still excludes Agent and Skill"
  else
    fail_msg "tdd-implementer tools must exclude:$BAD (Direction 3 is rejected — see #1225)"
    echo "    tools line: $TOOLS_LINE"
  fi
fi

# --- A6: the loud-refusal sentinel exists in the agent body -----------------
echo "A6: tdd-implementer declares the CAPABILITY-REFUSED sentinel"
inc
if printf '%s' "$AGENT_BODY" | grep -qF "CAPABILITY-REFUSED"; then
  pass_msg "agent body carries the literal CAPABILITY-REFUSED token"
else
  fail_msg "agents/tdd-implementer.md body must carry the literal sentinel 'CAPABILITY-REFUSED'"
fi

# --- A7: substitution is explicitly forbidden -------------------------------
echo "A7: '## Forbidden' bans substituting for a mandated Skill invocation"
inc
if [ -z "$FORBIDDEN" ]; then
  fail_msg "no '## Forbidden' section body in agents/tdd-implementer.md"
elif printf '%s' "$FORBIDDEN" | grep -i "substitut" | grep -qF "Skill"; then
  pass_msg "a single Forbidden bullet bans substituting for a mandated Skill invocation"
else
  fail_msg "'## Forbidden' needs ONE line containing BOTH 'substitut' and 'Skill' (silent substitution = self-grading)"
fi

# --- A8: execute-issue-plan Step 8 names its owner role ---------------------
echo "A8: execute-issue-plan Step 8 names the PR-opening owner role"
inc
if [ -z "$STEP8" ]; then
  fail_msg "could not extract Step 8 from skills/execute-issue-plan/SKILL.md"
elif printf '%s' "$STEP8" | grep -qF "Step 8 owner" \
   && printf '%s' "$STEP8" | grep -qF "CAPABILITY-REFUSED" \
   && printf '%s' "$STEP8" | grep -qi "orchestrator"; then
  pass_msg "Step 8 declares its owner, the orchestrator on PATH C, and the refusal sentinel"
else
  fail_msg "Step 8 must contain the literal 'Step 8 owner', 'CAPABILITY-REFUSED', and an 'orchestrator' owner"
fi

# --- A9: superpowers-integration row attributes the invocation --------------
echo "A9: superpowers-integration row attributes requesting-code-review to a role"
inc
if [ -z "$DOCROW" ]; then
  fail_msg "no plan-issue -> requesting-code-review row in docs/superpowers-integration.md"
elif printf '%s' "$DOCROW" | grep -qE 'orchestrator|PR-opening role'; then
  pass_msg "doc row attributes the invocation to the orchestrator / PR-opening role"
else
  fail_msg "doc row must attribute the invocation ('orchestrator' or 'PR-opening role'), not just 'final Task N in plan output'"
fi

# --- A10: the fullsend PATH C runbook carries the ownership rule ------------
# fullsend/SKILL.md is what the PATH C orchestrator actually reads; the rule
# does not reach it via execute-issue-plan Step 8 alone.
echo "A10: fullsend PATH C runbook line states the Step 8 ownership rule"
inc
if [ -z "$FSC" ]; then
  fail_msg "could not find the PATH C execute-routing bullet in skills/fullsend/SKILL.md"
elif printf '%s' "$FSC" | grep -qF "Step 8" \
   && printf '%s' "$FSC" | grep -qF '`Skill` tool'; then
  pass_msg "PATH C runbook line names Step 8 and the missing \`Skill\` tool"
else
  fail_msg "PATH C runbook bullet must name 'Step 8' and the missing '\`Skill\` tool' so the orchestrator runs the review itself"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
