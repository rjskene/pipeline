#!/bin/bash
set -uo pipefail

# Regression guard for issue #1208 Task 3 — Step 6a orchestrator-owned recovery
# with NO re-ask of the dropped-out agent, plus a bounded escalation ladder.
#
# #1208's second drop-out is the whole point of this guard: after
# `ACTION=recover-push REASON=branch-unpushed` came back from
# scripts/verify-execute-completion.sh, the orchestrator RESUMED the dropped-out
# agent with an explicit "STOP WAITING / run everything in the FOREGROUND"
# message — and it dropped out a SECOND time, idle ~11 minutes with the branch
# still unpushed. An agent that narrate-and-yielded once has demonstrated the
# failure mode and reproduces it on resume.
#
# So Step 6a's recovery must be ORCHESTRATOR-OWNED (the orchestrator does the
# push / PR / label work itself, never re-asking the stranded agent) and the
# retry must be BOUNDED: act → re-run the helper once → on a repeated token
# escalate to a FRESH agent at most once → then a per-issue `recover-exhausted`
# scoped halt that does NOT halt the wave.
#
# Region-scoped to Step 6a so it cannot false-match recovery/resume prose
# elsewhere in the SKILL (Step 6's triage options, Step 6b's CI-fix loop table).
#
# Mirrors the ROOT / pass_msg / fail_msg / inc / `exit 1` shape of
# tests/test-execute-dispatch-prompt-hardening.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$ROOT/$SKILL" ]; then
  echo "FAIL: $SKILL not found under $ROOT" >&2
  exit 1
fi

# Extract the Step 6a region: from the `6a. **Post-dispatch completion
# verification` marker line up to (but not including) the next `6b.` /  `**6b.`
# step marker.
REGION="$(awk '
  /6a\. \*\*Post-dispatch completion verification/ {capturing=1}
  capturing && /^[[:space:]]*(\*\*)?6b\./ {capturing=0}
  capturing {print}
' "$ROOT/$SKILL")"

if [ -z "$REGION" ]; then
  echo "FAIL: could not extract the Step 6a region from $SKILL (markers '6a. **Post-dispatch completion verification' / '6b.' moved?)" >&2
  exit 1
fi

FLAT="$(tr '\n' ' ' <<< "$REGION")"

# ---------------------------------------------------------------------------
# 1. The no-re-ask directive is present: the orchestrator MUST NOT resume /
#    re-prompt / SendMessage the dropped-out agent.
# ---------------------------------------------------------------------------

inc
missing=""
grep -Fq  -- 'MUST NOT'    <<< "$FLAT" || missing="$missing 'MUST NOT'"
grep -Fiq -- 'resume'      <<< "$FLAT" || missing="$missing 'resume'"
grep -Fq  -- 'SendMessage' <<< "$FLAT" || missing="$missing 'SendMessage'"
if [ -z "$missing" ]; then
  pass_msg "no-re-ask: Step 6a forbids resuming/re-prompting/SendMessage-ing the dropped-out agent"
else
  fail_msg "no-re-ask: Step 6a is missing the no-re-ask directive (absent:$missing)"
fi

# ---------------------------------------------------------------------------
# 2. Recovery is explicitly orchestrator-owned.
# ---------------------------------------------------------------------------

inc
if grep -Fq -- 'orchestrator-owned' <<< "$FLAT"; then
  pass_msg "orchestrator-owned: Step 6a names the recovery as orchestrator-owned"
else
  fail_msg "orchestrator-owned: Step 6a never states that recover-* handling is 'orchestrator-owned'"
fi

# ---------------------------------------------------------------------------
# 3. The `recover-push` ACTION row itself is orchestrator-owned (row-scoped, so
#    a mention elsewhere in Step 6a cannot satisfy it).
# ---------------------------------------------------------------------------

ROW_PUSH="$(grep -E '^[[:space:]]*\| `recover-push`' <<< "$REGION")"

inc
if [ -z "$ROW_PUSH" ]; then
  fail_msg "recover-push-row: no \`recover-push\` row found in the Step 6a ACTION table"
elif grep -Fq -- 'orchestrator-owned' <<< "$ROW_PUSH"; then
  pass_msg "recover-push-row: the \`recover-push\` row is marked orchestrator-owned"
else
  fail_msg "recover-push-row: the \`recover-push\` row does not say 'orchestrator-owned'"
fi

# ---------------------------------------------------------------------------
# 4. The `recover-redispatch` ACTION row demands a FRESH agent and is bounded.
# ---------------------------------------------------------------------------

ROW_REDISPATCH="$(grep -E '^[[:space:]]*\| `recover-redispatch`' <<< "$REGION")"

inc
if [ -z "$ROW_REDISPATCH" ]; then
  fail_msg "recover-redispatch-row: no \`recover-redispatch\` row found in the Step 6a ACTION table"
else
  rd_missing=""
  grep -Fiq -- 'fresh'        <<< "$ROW_REDISPATCH" || rd_missing="$rd_missing 'fresh'"
  grep -Fiq -- 'at most once' <<< "$ROW_REDISPATCH" || rd_missing="$rd_missing 'at most once'"
  if [ -z "$rd_missing" ]; then
    pass_msg "recover-redispatch-row: re-dispatch demands a FRESH agent, bounded to at most once"
  else
    fail_msg "recover-redispatch-row: row is not fresh-and-bounded (absent:$rd_missing)"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Bounded escalation ladder: repeated token => escalate, then a per-issue
#    `recover-exhausted` scoped halt (never a wave halt).
# ---------------------------------------------------------------------------

inc
lad_missing=""
grep -Eiq 'same[^.]*repeats' <<< "$FLAT" || lad_missing="$lad_missing 'same...repeats'"
grep -Fq  -- 'recover-exhausted' <<< "$FLAT" || lad_missing="$lad_missing 'recover-exhausted'"
grep -Fiq -- 'scoped halt' <<< "$FLAT" || lad_missing="$lad_missing 'scoped halt'"
if [ -z "$lad_missing" ]; then
  pass_msg "escalation-ladder: a repeated recover-* token escalates and terminates at a per-issue recover-exhausted scoped halt"
else
  fail_msg "escalation-ladder: Step 6a has no bounded escalation ladder (absent:$lad_missing)"
fi

# ---------------------------------------------------------------------------
# 6. Negative guard: Step 6a must never instruct the orchestrator to hand the
#    recovery back to the stranded agent. Both shapes must MISS.
# ---------------------------------------------------------------------------

inc
banned=""
grep -Fiq -- 're-prompt the same agent' <<< "$FLAT" && banned="$banned 're-prompt the same agent'"
grep -Fiq -- 'ask the agent to push'    <<< "$FLAT" && banned="$banned 'ask the agent to push'"
if [ -z "$banned" ]; then
  pass_msg "no-handback: Step 6a never hands the recovery back to the dropped-out agent"
else
  fail_msg "no-handback: Step 6a re-asks the dropped-out agent (present:$banned)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
