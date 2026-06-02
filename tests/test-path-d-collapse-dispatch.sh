#!/usr/bin/env bash
set -euo pipefail

# RED-FIRST guard for issue #700 — "collapse PATH D ceremony".
#
# Asserts the collapsed PATH D dispatch contract across three SKILLs. The
# spec text these checks target is NOT yet present — every assertion below is
# expected to FAIL on first run, for the RIGHT reason (asserted spec text
# absent), until the SKILLs are updated.
#
# Style mirrors tests/test-path-d-auto-approve.sh and
# tests/test-run-skill-dispatch-routing.sh: whitespace-normalized body for
# tolerant `grep -qF` substring checks, plus windowed python3 substring checks
# for "token X appears near token Y" assertions.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# #763: the run→status rename moved ALL collapsed-PATH-D dispatch wiring out of
# the old /pipeline:run skill into fullsend's "Collapsed-D ceremony" / Dispatch-
# routing reference. The read-only /pipeline:status skill no longer carries any
# of it, so the Group-1 collapsed-D dispatch contract is now asserted against
# fullsend (same file as Group 2). The line-content Group-1 assertions (1a-1g)
# are all carried by fullsend's Collapsed-D ceremony; the windowed planning-branch
# carve-out assertion (1h) was DELETED — that "For planning ... PATH D carve-out"
# routing was specific to the old run skill's planning section and has no fullsend
# equivalent; in fullsend the equivalent contract is Group 2's split-dispatch +
# Step-1b PATH-D exclusion (assertion 2e), which is the canonical home.
RUN_SKILL="$SCRIPT_DIR/../skills/fullsend/SKILL.md"
FULLSEND_SKILL="$SCRIPT_DIR/../skills/fullsend/SKILL.md"
EXECUTE_SKILL="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$RUN_SKILL" "$FULLSEND_SKILL" "$EXECUTE_SKILL"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: SKILL.md not found at $f" >&2
    exit 1
  fi
done

# Whitespace-normalized bodies — collapse all whitespace runs to single spaces
# so multi-line markdown bullets match a single-line substring assertion.
RUN_BODY=$(tr '\n' ' ' < "$RUN_SKILL" | tr -s '[:space:]' ' ')
FULLSEND_BODY=$(tr '\n' ' ' < "$FULLSEND_SKILL" | tr -s '[:space:]' ' ')
EXECUTE_BODY=$(tr '\n' ' ' < "$EXECUTE_SKILL" | tr -s '[:space:]' ' ')

# Windowed substring helper: succeeds if NEEDLE appears within WINDOW chars of
# any ANCHOR occurrence in FILE. Echoes OK / MISS.
near() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
anchor = sys.argv[2]
needle = sys.argv[3]
window = int(sys.argv[4])
ok = False
for m in re.finditer(re.escape(anchor), text):
    if needle in text[m.start(): m.start() + window]:
        ok = True
        break
print("OK" if ok else "MISS")
PY
}

# =====================================================================
# Group 1 — skills/run/SKILL.md: ONE collapsed inline Agent (classify+
# plan+execute carried forward), separate pr-eval agent, max-3 bound,
# BARE tdd-implementer form, negation phrasing preserved.
# =====================================================================

echo "Group 1: run/SKILL.md collapsed PATH D dispatch"

# (1a) ONE collapsed inline Agent doing classify+plan+execute — a single
# carried-forward context, not three separate Agent dispatches.
inc
if printf '%s' "$RUN_BODY" | grep -qiE 'one (collapsed )?inline `?Agent`?' \
   && printf '%s' "$RUN_BODY" | grep -qiE 'classify ?\+ ?plan ?\+ ?execute|classify, plan, (and )?execute'; then
  pass_msg "(1a) ONE collapsed inline Agent doing classify+plan+execute described"
else
  fail_msg "(1a) run/SKILL.md missing 'one collapsed inline Agent' + classify+plan+execute phrasing"
fi

# (1b) carried-forward context (single context), NOT three separate dispatches.
inc
if printf '%s' "$RUN_BODY" | grep -qiE 'carried[- ]forward|single (carried[- ]forward )?context' \
   && printf '%s' "$RUN_BODY" | grep -qiE 'not three separate|not three Agent|single Agent'; then
  pass_msg "(1b) single carried-forward context, not three separate Agent dispatches"
else
  fail_msg "(1b) run/SKILL.md missing 'carried-forward / single context, not three separate dispatches'"
fi

# (1c) pr-eval stays a SEPARATE inline agent (evaluator independence) within
# the D dispatch window.
inc
PR_EVAL_NEAR=$(near "$RUN_SKILL" "PATH D" "separate inline agent" 600)
if [ "$PR_EVAL_NEAR" = "OK" ] \
   || { printf '%s' "$RUN_BODY" | grep -qiE 'pr-eval (stays|remains) a separate inline agent' \
        && printf '%s' "$RUN_BODY" | grep -qiE 'evaluator independence'; }; then
  pass_msg "(1c) pr-eval stays a SEPARATE inline agent (evaluator independence) in D window"
else
  fail_msg "(1c) run/SKILL.md missing 'pr-eval separate inline agent / evaluator independence' note in D window"
fi

# (1d) max 3 concurrent inline D bound.
inc
if printf '%s' "$RUN_BODY" | grep -qiE 'max 3 concurrent inline'; then
  pass_msg "(1d) 'max 3 concurrent inline' D bound stated"
else
  fail_msg "(1d) run/SKILL.md missing 'max 3 concurrent inline' bound"
fi

# (1e) BARE Agent(subagent_type='tdd-implementer' still used (regression guard).
inc
if printf '%s' "$RUN_BODY" | grep -qF "Agent(subagent_type='tdd-implementer'"; then
  pass_msg "(1e) BARE Agent(subagent_type='tdd-implementer' still present"
else
  fail_msg "(1e) run/SKILL.md missing BARE Agent(subagent_type='tdd-implementer'"
fi

# (1f) NOT the namespaced pipeline:tdd-implementer form.
inc
if printf '%s' "$RUN_BODY" | grep -qF "pipeline:tdd-implementer"; then
  fail_msg "(1f) run/SKILL.md must use BARE tdd-implementer, NOT pipeline:tdd-implementer"
else
  pass_msg "(1f) namespaced pipeline:tdd-implementer form absent (BARE form preserved)"
fi

# (1g) negation phrasing preserved: No spawn-claude.sh / no tmux / no run-queue.
inc
if printf '%s' "$RUN_BODY" | grep -qF "No spawn-claude.sh" \
   && printf '%s' "$RUN_BODY" | grep -qiE 'no tmux' \
   && printf '%s' "$RUN_BODY" | grep -qiE 'no run-queue'; then
  pass_msg "(1g) 'No spawn-claude.sh' / 'no tmux' / 'no run-queue' negation preserved"
else
  fail_msg "(1g) run/SKILL.md missing one of: 'No spawn-claude.sh', 'no tmux', 'no run-queue'"
fi

# (1h) DELETED for #763: the "For planning ... PATH D carve-out" planning-branch
# routing was specific to the old /pipeline:run skill's planning section, which
# was removed in the run→status rename (status is read-only and dispatches
# nothing). fullsend has no "For planning" planning-branch — its equivalent
# PATH-D contract is the Step-1b per-stage classify/plan EXCLUSION asserted by
# Group 2's (2e) below, which is the canonical home. Verified obsolete: neither
# "For planning" nor "PATH D carve-out" exists in fullsend.

# =====================================================================
# Group 2 — skills/fullsend/SKILL.md: split-dispatch where D fans out as a
# concurrent inline Agent batch in the FOREGROUND while B/C run-queue runs
# via run_in_background; D consumes zero queue slots; max 3 concurrent inline.
# =====================================================================

echo "Group 2: fullsend/SKILL.md split-dispatch (D foreground, B/C background)"

# (2a) split-dispatch: D as concurrent inline Agent batch in the FOREGROUND.
inc
if printf '%s' "$FULLSEND_BODY" | grep -qiE 'concurrent inline `?Agent`? batch' \
   && printf '%s' "$FULLSEND_BODY" | grep -qiE 'foreground'; then
  pass_msg "(2a) D fans out as a concurrent inline Agent batch in the FOREGROUND"
else
  fail_msg "(2a) fullsend/SKILL.md missing 'concurrent inline Agent batch' + 'foreground' for D"
fi

# (2b) PATH C-only run-queue runs via run_in_background (issue #748: PATH B left
# the run-queue for the inline foreground side, so the run-queue is C-only).
inc
if printf '%s' "$FULLSEND_BODY" | grep -qiE 'C-only run-queue|PATH C run-queue' \
   && printf '%s' "$FULLSEND_BODY" | grep -qF "run_in_background"; then
  pass_msg "(2b) PATH C-only run-queue runs via run_in_background"
else
  fail_msg "(2b) fullsend/SKILL.md missing 'C-only run-queue ... run_in_background' split"
fi

# (2c) D consumes zero queue slots / costs no run-queue slot.
inc
if printf '%s' "$FULLSEND_BODY" | grep -qiE 'zero queue slots|no run-queue slot|costs? no (run-)?queue slot|consumes? no queue slot'; then
  pass_msg "(2c) D consumes zero queue slots / costs no run-queue slot"
else
  fail_msg "(2c) fullsend/SKILL.md missing 'D consumes zero queue slots / costs no run-queue slot'"
fi

# (2d) max 3 concurrent inline D bound (in fullsend too).
inc
if printf '%s' "$FULLSEND_BODY" | grep -qiE 'max 3 concurrent inline'; then
  pass_msg "(2d) 'max 3 concurrent inline' D bound stated in fullsend"
else
  fail_msg "(2d) fullsend/SKILL.md missing 'max 3 concurrent inline' bound for D"
fi

# (2e) Step 1b explicitly EXCLUDES PATH D from per-stage classify/plan dispatch
# (D's classify+plan run inside the collapsed foreground inline Agent at execute).
inc
STEP1B_D=$(near "$FULLSEND_SKILL" "1b. Dispatch classify and plan" "PATH D exclusion" 1400)
STEP1B_D2=$(near "$FULLSEND_SKILL" "1b. Dispatch classify and plan" "EXCLUDED from this per-stage classify/plan dispatch" 1400)
if [ "$STEP1B_D" = "OK" ] || [ "$STEP1B_D2" = "OK" ]; then
  pass_msg "(2e) fullsend Step 1b EXCLUDES PATH D from per-stage classify/plan dispatch"
else
  fail_msg "(2e) fullsend Step 1b missing explicit PATH D exclusion from per-stage classify/plan dispatch"
fi

# ---------------------------------------------------------------------
# Group 2 (#748): PATH B joins the inline foreground side; the backgrounded
# tmux run-queue is now C-only. Conflict-free B issues fan out as a concurrent
# inline Agent batch (max 3, zero queue slots) exactly like A/D.
# ---------------------------------------------------------------------

echo "Group 2 (#748): fullsend PATH B inline foreground / C-only run-queue"

# (2f) conflict-free PATH B fans out on the inline foreground side alongside A/D.
inc
if printf '%s' "$FULLSEND_BODY" | grep -qiE 'conflict-free PATH A/B/D|PATH A/B/D issues fan out' \
   || printf '%s' "$FULLSEND_BODY" | grep -qiE 'PATH B[^.]*inline `?Agent`? batch[^.]*foreground|foreground[^.]*PATH B'; then
  pass_msg "(2f) PATH B joins the inline foreground Agent batch alongside A/D"
else
  fail_msg "(2f) fullsend/SKILL.md missing PATH B on the inline foreground side"
fi

# (2g) PATH B is NO LONGER paired with the backgrounded run-queue (drift guard:
# the old 'B/C run-queue' framing must be gone — run-queue is C-only).
inc
if printf '%s' "$FULLSEND_BODY" | grep -qiE 'B/C run-queue'; then
  fail_msg "(2g) fullsend still pairs PATH B with the run-queue ('B/C run-queue' should be C-only)"
else
  pass_msg "(2g) PATH B no longer paired with the backgrounded run-queue (C-only)"
fi

# =====================================================================
# Group 3 — skills/execute-issue-plan/SKILL.md: the collapsed D agent carries
# classify+plan context forward and does NOT re-read the plan comment; emits
# stage checkpoints (## Classification + path label, ## Implementation Plan +
# plan-pending) as inline side-effects.
# =====================================================================

echo "Group 3: execute-issue-plan/SKILL.md collapsed-D context carry-forward + checkpoints"

# (3a) carries classify+plan context forward.
inc
if printf '%s' "$EXECUTE_BODY" | grep -qiE 'carr(y|ies|ied)[- ]forward .*classify|classify ?\+ ?plan context (carried )?forward|carries (the )?classify\+plan context'; then
  pass_msg "(3a) collapsed D agent carries classify+plan context forward"
else
  fail_msg "(3a) execute-issue-plan/SKILL.md missing 'carries classify+plan context forward'"
fi

# (3b) does NOT re-read the plan comment.
inc
if printf '%s' "$EXECUTE_BODY" | grep -qiE 'does NOT re-read the plan comment|no re-read of the plan comment|skip(s|ping)? the plan-comment re-?read'; then
  pass_msg "(3b) collapsed D agent does NOT re-read the plan comment"
else
  fail_msg "(3b) execute-issue-plan/SKILL.md missing 'does NOT re-read the plan comment'"
fi

# (3c) emits a ## Classification checkpoint + path label as an inline side-effect.
inc
if printf '%s' "$EXECUTE_BODY" | grep -qiE 'checkpoint' \
   && printf '%s' "$EXECUTE_BODY" | grep -qF "## Classification" \
   && printf '%s' "$EXECUTE_BODY" | grep -qiE 'path label'; then
  pass_msg "(3c) emits '## Classification' + path label checkpoint inline"
else
  fail_msg "(3c) execute-issue-plan/SKILL.md missing '## Classification' + path-label checkpoint"
fi

# (3d) emits a ## Implementation Plan checkpoint + plan-pending label inline.
inc
if printf '%s' "$EXECUTE_BODY" | grep -qiE 'checkpoint' \
   && printf '%s' "$EXECUTE_BODY" | grep -qF "## Implementation Plan" \
   && printf '%s' "$EXECUTE_BODY" | grep -qF "plan-pending"; then
  pass_msg "(3d) emits '## Implementation Plan' + plan-pending checkpoint inline"
else
  fail_msg "(3d) execute-issue-plan/SKILL.md missing '## Implementation Plan' + plan-pending checkpoint"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
