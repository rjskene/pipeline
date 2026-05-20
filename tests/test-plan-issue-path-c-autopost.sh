#!/bin/bash
set -euo pipefail

# Tests for issue #326: the plan-issue skill prose must read uniformly across
# PATH A/B/C as an end-to-end skill that the dispatched agent itself owns.
# A PATH C subagent dispatched via Agent(...) must NOT interpret Steps 6-7 as
# a hand-off to the orchestrator — the post-plan.sh invocation is always its
# own work. These greps lock the prose down.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../skills/plan-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: plan-issue SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi

# --- helpers ----------------------------------------------------------------

# Body between "^## Steps" and the first "#### Task 0" heading (the shared,
# path-agnostic Steps prose).
pre_block() {
  awk '
    /^## Steps/        { capture = 1; next }
    capture && /^#### Task 0/ { exit }
    capture            { print }
  ' "$SKILL_FILE"
}

# Body between the LAST "#### Task 0 — PATH" block and "^## Revision handling"
# (the shared Steps 6-8 prose that follows the per-path Task 0 blocks).
post_block() {
  awk '
    /^#### Task 0 — PATH/ { lastpath = NR }
    { lines[NR] = $0 }
    /^## Revision handling/ { end = NR; exit }
    END {
      if (lastpath && end) {
        for (i = lastpath + 1; i < end; i++) print lines[i]
      }
    }
  ' "$SKILL_FILE"
}

# Body of one specific "#### Task 0 — PATH X" block. Closes at the next
# "#### " heading, the next "## " or "### " section, or the next numbered
# Step (e.g. "6. **Write ..."), whichever comes first. This matters for
# PATH C — without the numbered-step terminator, the block would swallow
# Steps 6-8, which live AFTER PATH C in the document.
extract_path_block() {
  local letter="$1"
  awk -v start="^#### Task 0 — PATH ${letter}" '
    $0 ~ start                                { inblock = 1; print; next }
    inblock && (/^#### / || /^### / || /^## / || /^[0-9]+\. \*\*/) { inblock = 0 }
    inblock                                   { print }
  ' "$SKILL_FILE"
}

# Lines covering Steps 6 and 7 (from "^6\." through line just before "^8\.").
steps_6_7() {
  awk '
    /^6\. \*\*/  { capture = 1 }
    /^8\. \*\*/  { exit }
    capture      { print }
  ' "$SKILL_FILE"
}

# Step 8 paragraph (from "^8\. \*\*Report back" up to next "^## " or "^[0-9]+\.").
step_8() {
  awk '
    /^8\. \*\*Report back/  { capture = 1 }
    capture && /^## /       { exit }
    capture                 { print }
  ' "$SKILL_FILE"
}

# --- Test 1: post-step uniformity ------------------------------------------
echo "Test 1: post-plan.sh invocation lives OUTSIDE every #### Task 0 — PATH X block"
inc
PRE=$(pre_block)
POST=$(post_block)
OUT_OF_BLOCK_HIT=0
if echo "$PRE"  | grep -qF "post-plan.sh"; then OUT_OF_BLOCK_HIT=1; fi
if echo "$POST" | grep -qF "post-plan.sh"; then OUT_OF_BLOCK_HIT=1; fi

IN_BLOCK_HIT=0
for L in A B C; do
  BLK=$(extract_path_block "$L")
  if echo "$BLK" | grep -qF "post-plan.sh"; then IN_BLOCK_HIT=1; fi
done

if [ "$OUT_OF_BLOCK_HIT" -eq 1 ] && [ "$IN_BLOCK_HIT" -eq 0 ]; then
  pass_msg "post-plan.sh appears only in shared Steps prose, not inside any per-path Task 0 block"
else
  if [ "$OUT_OF_BLOCK_HIT" -eq 0 ]; then
    fail_msg "post-plan.sh not found in shared Steps prose (must live in Step 7, applying to all paths)"
  fi
  if [ "$IN_BLOCK_HIT" -eq 1 ]; then
    fail_msg "post-plan.sh appears inside a #### Task 0 — PATH X block (bleeds into per-path discipline)"
  fi
fi

# --- Test 2: imperative voice on draft+post --------------------------------
echo "Test 2: Steps 6-7 contain imperative second-person voice on draft+post (YOU MUST x2)"
inc
S67=$(steps_6_7)
# Count case-insensitively, anchored to whole-word "YOU MUST".
COUNT=$(echo "$S67" | grep -ciE '\bYOU MUST\b' || true)
if [ "$COUNT" -ge 2 ]; then
  pass_msg "YOU MUST appears >=2 times across Steps 6-7 (draft + post)"
else
  fail_msg "Steps 6-7 contain only $COUNT YOU MUST occurrences; need >=2 (one for draft write, one for post-plan.sh invocation)"
fi

# --- Test 3: no PATH-C handoff escape phrases ------------------------------
echo "Test 3: no hand-off escape phrases anywhere in SKILL.md"
inc
HANDOFF_HITS=0
for phrase in \
  "return the plan to the orchestrator" \
  "caller will post" \
  "caller posts" \
  "orchestrator will post" \
  "the orchestrator handles posting" \
  "hand off the plan" \
  "hand the plan off"; do
  if grep -qiF "$phrase" "$SKILL_FILE"; then
    fail_msg "found hand-off escape phrase: \"$phrase\""
    HANDOFF_HITS=$((HANDOFF_HITS + 1))
  fi
done

# "return as terminal" — permissive sense only. The legitimate occurrence is
# the negative directive "Returning the plan as terminal agent output is a
# skill failure". Allowlist by checking that "failure" appears within 30
# chars after each match.
TERMINAL_MATCHES=$(grep -niE "return(ing)? .*(as )?terminal" "$SKILL_FILE" || true)
TERMINAL_BAD=0
if [ -n "$TERMINAL_MATCHES" ]; then
  while IFS= read -r line; do
    # Strip leading "N:" line-number prefix from grep -n output.
    body=$(echo "$line" | sed -E 's/^[0-9]+://')
    # Look at the 30 chars *after* the match (or end of line).
    if ! echo "$body" | grep -qiE "return(ing)? .{0,80}terminal.{0,30}failure"; then
      fail_msg "non-allowlisted 'return ... terminal' phrase: $body"
      TERMINAL_BAD=1
    fi
  done <<< "$TERMINAL_MATCHES"
fi

if [ "$HANDOFF_HITS" -eq 0 ] && [ "$TERMINAL_BAD" -eq 0 ]; then
  pass_msg "no hand-off escape phrases present (allowlisted 'terminal ... failure' OK)"
fi

# --- Test 4: subagent dispatch contract present ----------------------------
echo "Test 4: a Subagent dispatch contract / end-to-end-skill paragraph exists"
inc
if grep -qE "(Subagent dispatch contract|This skill is end-to-end|terminal contract)" "$SKILL_FILE"; then
  pass_msg "Subagent dispatch contract paragraph present"
else
  fail_msg "no 'Subagent dispatch contract' / 'This skill is end-to-end' / 'terminal contract' paragraph found"
fi

# --- Test 5: Step 8 final-message contract ---------------------------------
echo "Test 5: Step 8 ties the success report to post-plan.sh exiting 0"
inc
S8=$(step_8)
if echo "$S8" | grep -qiF "post-plan.sh" \
   && echo "$S8" | grep -qiE "(exit|exits|exited).{0,40}(0|success)"; then
  pass_msg "Step 8 references post-plan.sh + an exit-0/success condition"
else
  fail_msg "Step 8 missing the post-plan.sh + exit-0/success final-message contract"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
