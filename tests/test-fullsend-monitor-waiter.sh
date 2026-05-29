#!/bin/bash
# Asserts that skills/fullsend/SKILL.md Steps 6 and 7 use a single
# event-driven `Monitor` invocation (against the queue runner's captured
# stdout via BashOutput) instead of the old single-shot
# `tail -F ... | grep -m1 "EVENT: queue-complete"` waiter, and that a
# `### Triage on agent-stalled wakes` sub-section documents the wake-loop
# semantics + four-option stall response.
#
# Introduced by issue #437 (task 2).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_PATH="$SCRIPT_DIR/../skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_PATH" ]; then
  fail_msg "SKILL.md not found at $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

# --- Extract Step 6 section: from `6. **Execute** [(wave N)]` up to (not incl)
# the next step boundary. #626 restructured Steps 5-7 into a per-wave loop and
# renamed the heading to `6. **Execute (wave N)**`, so the anchor matches with
# OR without the `(wave N)` suffix. Terminate at the next sub-step (`6b.`) or
# the next top-level numbered step / H3 boundary so the capture is robust to
# 6b's presence or removal. ---
STEP6=$(awk '
  /^6\. \*\*Execute/                 { capture=1; print; next }
  capture && /^6b\./                 { exit }
  capture && /^[0-9]+\. /            { exit }
  capture && /^### /                 { exit }
  capture                            { print }
' "$SKILL_PATH")

# --- Extract Step 7 section: from `7. **Evaluate PRs** [(wave N)]` up to (not
# incl) the next step boundary (`7b.`, the next top-level numbered step, or the
# next H3 such as `### Inter-wave pull`). Anchor matches with or without the
# `(wave N)` suffix (#626). ---
STEP7=$(awk '
  /^7\. \*\*Evaluate PRs/            { capture=1; print; next }
  capture && /^7b\./                 { exit }
  capture && /^[0-9]+\. /            { exit }
  capture && /^### /                 { exit }
  capture                            { print }
' "$SKILL_PATH")

# --- Extract the triage sub-section (whole file scope is fine).
# The heading may be indented inside a numbered-list item, so allow
# leading whitespace; terminate at the next top-level numbered step
# (e.g. `6b.` / `7.`) or a non-### markdown heading. ---
TRIAGE=$(awk '
  /^[[:space:]]*### Triage on agent-stalled wakes/ { capture=1 }
  capture && /^[0-9]+b?\. / { exit }
  capture && /^## / { exit }
  capture { print }
' "$SKILL_PATH")

if [ -z "$STEP6" ]; then
  fail_msg "could not extract Step 6 section (anchor '6. **Execute[ (wave N)]**' .. next step boundary)"
fi
if [ -z "$STEP7" ]; then
  fail_msg "could not extract Step 7 section (anchor '7. **Evaluate PRs[ (wave N)]**' .. next step boundary)"
fi

MONITOR_REGEX='EVENT: (agent-stalled|agent-finished|queue-complete)'

# === Old single-shot waiter is gone (both sections) ===
inc
if echo "$STEP6" | grep -qF 'tail -F' && echo "$STEP6" | grep -qF 'grep -m1 "EVENT: queue-complete"'; then
  fail_msg "Step 6 still contains the OLD single-shot waiter (tail -F + grep -m1 queue-complete)"
else
  pass_msg "Step 6 no longer contains the old single-shot waiter"
fi

inc
if echo "$STEP7" | grep -qF 'tail -F' && echo "$STEP7" | grep -qF 'grep -m1 "EVENT: queue-complete"'; then
  fail_msg "Step 7 still contains the OLD single-shot waiter (tail -F + grep -m1 queue-complete)"
else
  pass_msg "Step 7 no longer contains the old single-shot waiter"
fi

# === Monitor invocation present (both sections) ===
inc
if echo "$STEP6" | grep -qF 'Monitor'; then
  pass_msg "Step 6 references Monitor invocation"
else
  fail_msg "Step 6 does not reference a Monitor invocation"
fi

inc
if echo "$STEP7" | grep -qF 'Monitor'; then
  pass_msg "Step 7 references Monitor invocation"
else
  fail_msg "Step 7 does not reference a Monitor invocation"
fi

# === Exact filter regex alternation present (both sections) ===
inc
if echo "$STEP6" | grep -qF "$MONITOR_REGEX"; then
  pass_msg "Step 6 contains filter regex '$MONITOR_REGEX'"
else
  fail_msg "Step 6 does not contain filter regex '$MONITOR_REGEX'"
fi

inc
if echo "$STEP7" | grep -qF "$MONITOR_REGEX"; then
  pass_msg "Step 7 contains filter regex '$MONITOR_REGEX'"
else
  fail_msg "Step 7 does not contain filter regex '$MONITOR_REGEX'"
fi

# === agent-finished used as the failure token in the filter, NOT a
# nonexistent agent-failed EVENT token (both sections). Prose may mention
# "no separate agent-failed" to explain its absence; what must NOT appear
# is an `EVENT: agent-failed` token (the filter must key off
# agent-finished outcome=failed). ===
inc
if echo "$STEP6" | grep -qF 'EVENT: agent-failed'; then
  fail_msg "Step 6 uses nonexistent 'EVENT: agent-failed' token (must be agent-finished)"
else
  pass_msg "Step 6 does not use an 'EVENT: agent-failed' token"
fi

inc
if echo "$STEP7" | grep -qF 'EVENT: agent-failed'; then
  fail_msg "Step 7 uses nonexistent 'EVENT: agent-failed' token (must be agent-finished)"
else
  pass_msg "Step 7 does not use an 'EVENT: agent-failed' token"
fi

# The failure path keys off agent-finished outcome=failed (both sections).
inc
if echo "$STEP6" | grep -qF 'agent-finished'; then
  pass_msg "Step 6 keys failure off agent-finished"
else
  fail_msg "Step 6 does not reference agent-finished"
fi

inc
if echo "$STEP7" | grep -qF 'agent-finished'; then
  pass_msg "Step 7 keys failure off agent-finished"
else
  fail_msg "Step 7 does not reference agent-finished"
fi

# === Timeout preserved (both sections) ===
inc
if echo "$STEP6" | grep -qF 'timeout_ms=7200000'; then
  pass_msg "Step 6 preserves timeout_ms=7200000"
else
  fail_msg "Step 6 does not contain timeout_ms=7200000"
fi

inc
if echo "$STEP7" | grep -qF 'timeout_ms=7200000'; then
  pass_msg "Step 7 preserves timeout_ms=7200000"
else
  fail_msg "Step 7 does not contain timeout_ms=7200000"
fi

# === Wake channel = BashOutput / captured stdout, NOT queue-*.log tail (both) ===
inc
if echo "$STEP6" | grep -qF 'BashOutput'; then
  pass_msg "Step 6 names BashOutput as the wake channel"
else
  fail_msg "Step 6 does not name BashOutput as the wake channel"
fi

inc
if echo "$STEP7" | grep -qF 'BashOutput'; then
  pass_msg "Step 7 names BashOutput as the wake channel"
else
  fail_msg "Step 7 does not name BashOutput as the wake channel"
fi

# Negative: no instruction to tail queue-*.log within either section.
inc
if echo "$STEP6" | grep -qF 'tail -F' && echo "$STEP6" | grep -qF 'queue-*.log'; then
  fail_msg "Step 6 still instructs to tail queue-*.log"
else
  pass_msg "Step 6 does not instruct to tail queue-*.log"
fi

inc
if echo "$STEP7" | grep -qF 'tail -F' && echo "$STEP7" | grep -qF 'queue-*.log'; then
  fail_msg "Step 7 still instructs to tail queue-*.log"
else
  pass_msg "Step 7 does not instruct to tail queue-*.log"
fi

# === Triage sub-section exists ===
inc
if echo "$TRIAGE" | grep -qF '### Triage on agent-stalled wakes'; then
  pass_msg "'### Triage on agent-stalled wakes' heading exists"
else
  fail_msg "'### Triage on agent-stalled wakes' heading not found"
fi

# Four options present in triage.
inc
if echo "$TRIAGE" | grep -qiE 'subscript'; then
  pass_msg "triage option 1: kill the wedged subscript present"
else
  fail_msg "triage option 1 (kill subscript) not found"
fi

inc
if echo "$TRIAGE" | grep -qiE 'kill the whole executor|whole executor'; then
  pass_msg "triage option 2: kill the whole executor present"
else
  fail_msg "triage option 2 (kill executor) not found"
fi

inc
if echo "$TRIAGE" | grep -qiE 'wait out the timeout'; then
  pass_msg "triage option 3: wait out the timeout present"
else
  fail_msg "triage option 3 (wait out timeout) not found"
fi

inc
if echo "$TRIAGE" | grep -qiE 'skip the issue'; then
  pass_msg "triage option 4: skip the issue present"
else
  fail_msg "triage option 4 (skip issue) not found"
fi

# === Wake-loop semantics: all four event outcomes spelled out ===
inc
if echo "$TRIAGE" | grep -qF 'queue-complete' && echo "$TRIAGE" | grep -qiE 'terminal'; then
  pass_msg "wake-loop: queue-complete documented as terminal"
else
  fail_msg "wake-loop: queue-complete terminal semantics not documented"
fi

inc
if echo "$TRIAGE" | grep -qF 'agent-stalled' && echo "$TRIAGE" | grep -qiE 'triage'; then
  pass_msg "wake-loop: agent-stalled triggers triage then re-enters Monitor"
else
  fail_msg "wake-loop: agent-stalled triage/re-enter semantics not documented"
fi

inc
if echo "$TRIAGE" | grep -qF 'agent-finished outcome=failed'; then
  pass_msg "wake-loop: agent-finished outcome=failed documented"
else
  fail_msg "wake-loop: agent-finished outcome=failed not documented"
fi

inc
if echo "$TRIAGE" | grep -qF 'agent-finished outcome=success' && echo "$TRIAGE" | grep -qiE 'no-op'; then
  pass_msg "wake-loop: agent-finished outcome=success documented as no-op wake"
else
  fail_msg "wake-loop: agent-finished outcome=success no-op semantics not documented"
fi

# issue #489: the run-queue runner emits a new terminal token when it frees a
# wedged evaluator slot (verdict Approved but manual-merge / block-* skip). The
# wake-loop must document it as a no-op wake (mirrors outcome=success).
inc
if echo "$TRIAGE" | grep -qF 'agent-finished outcome=approved-manual-merge' && echo "$TRIAGE" | grep -qiE 'no-op'; then
  pass_msg "wake-loop: agent-finished outcome=approved-manual-merge documented as no-op wake"
else
  fail_msg "wake-loop: agent-finished outcome=approved-manual-merge no-op semantics not documented"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
