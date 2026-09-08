#!/bin/bash
set -uo pipefail
#
# Tests for scripts/evolve-loop.sh — the session-per-cycle evolve wrapper
# (issue #1303, tracker #1271).
#
# Claude Code loads a plugin's skill/agent/hook bodies ONCE per session, so a
# merged harness fix is invisible until the operator restarts. The wrapper runs
# one fresh `claude -p` per cycle, which is what makes the loop self-updating.
#
# HERMETIC BY CONSTRUCTION. Nothing here touches the network, a real tracker,
# or the real clone:
#   * `gh` and `claude` are STUBS on PATH that append to a call log; the
#     `claude` stub optionally execs a per-scenario script so a scenario can
#     print a `HEADLESS-DEFAULT:` line and/or rewrite the tracker body.
#   * `usage-gate.sh` / `evolve-projection.sh` are invoked by ABSOLUTE PATH by
#     the wrapper, which a PATH shim cannot intercept, so they are replaced
#     through the wrapper's own `EVOLVE_LOOP_USAGE_GATE` /
#     `EVOLVE_LOOP_PROJECTION` seams. `EVOLVE_LOOP_SLEEP_CMD` replaces `sleep`,
#     so no scenario ever waits.
#   * cwd for every run is a scratch dir under `mktemp -d`, so the wrapper's
#     `.claude/scratch/evolve-loop/` writes never touch the real clone.
#
# `timeout 20` in run_helper is load-bearing twice over: an arg-parse bug that
# fails to consume its token spins the parser forever, AND an unbounded
# relaunch loop would otherwise run until the suite's own cap. Scenarios 8 and
# 8c assert `RC != 124` explicitly so a runaway is a FAIL, not a green.
#
# BEHAVIOUR TESTS ONLY — nothing greps SKILL.md / CLAUDE.md / doc prose.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/evolve-loop.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

CALLS="$TMP/calls.log"
ALL_CALLS="$TMP/all-calls.log"
LABELS_FILE="$TMP/labels.txt"
BODY_FILE="$TMP/body.md"
BODY_DONE="$TMP/body-done.md"
GATE_LINES="$TMP/gate-lines.txt"
PROJ_LINES="$TMP/proj-lines.txt"
GATE_COUNT="$TMP/gate.count"
PROJ_COUNT="$TMP/proj.count"
CLAUDE_COUNT="$TMP/claude.count"
PROJ_ARGV="$TMP/proj-argv.log"
SLEEP_LOG="$TMP/sleep.log"
CLAUDE_SCRIPT="$TMP/claude-script"

: > "$ALL_CALLS"

# Every seam the stubs read is exported once; scenarios reconfigure by writing
# the FILES these point at, never by re-exporting.
export LOOP_TEST_CALLS="$CALLS"
export LOOP_TEST_LABELS="$LABELS_FILE"
export LOOP_TEST_BODY="$BODY_FILE"
export LOOP_TEST_BODY_DONE="$BODY_DONE"
export LOOP_TEST_GATE_LINES="$GATE_LINES"
export LOOP_TEST_PROJ_LINES="$PROJ_LINES"
export LOOP_TEST_GATE_COUNT="$GATE_COUNT"
export LOOP_TEST_PROJ_COUNT="$PROJ_COUNT"
export LOOP_TEST_CLAUDE_COUNT="$CLAUDE_COUNT"
export LOOP_TEST_PROJ_ARGV="$PROJ_ARGV"
export LOOP_TEST_SLEEP_LOG="$SLEEP_LOG"
export LOOP_TEST_CLAUDE_SCRIPT="$CLAUDE_SCRIPT"
export LOOP_TEST_RESUME_AT="--"

TRACKER_N=1271
FUTURE="$(date -u -d '+2 hours' +%FT%TZ 2>/dev/null || echo '2099-01-01T00:00:00Z')"

# ---------------------------------------------------------------------------
# PATH stubs
# ---------------------------------------------------------------------------

# The wrapper reads the tracker with `--json labels` and `--json body` ONLY.
# Scenario 13 is the mechanical control that `--json comments` never appears.
cat > "$STUB_BIN/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$LOOP_TEST_CALLS"
case "$*" in
  *"--json labels"*) cat "$LOOP_TEST_LABELS" 2>/dev/null ;;
  *"--json body"*)   cat "$LOOP_TEST_BODY" 2>/dev/null ;;
esac
exit 0
GH
chmod +x "$STUB_BIN/gh"

# Records the argv AND the launch environment (neither `PIPELINE_HEADLESS` nor
# the unset `ALLOW_ORCHESTRATOR_EDIT` nor the background-wait ceiling is
# visible in argv, and all three are load-bearing for a headless cycle).
cat > "$STUB_BIN/claude" <<'CL'
#!/bin/bash
{
  echo "claude $*"
  echo "  launch-env PIPELINE_HEADLESS=${PIPELINE_HEADLESS:-unset}" \
       "CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-unset}" \
       "ALLOW_ORCHESTRATOR_EDIT=${ALLOW_ORCHESTRATOR_EDIT:-unset}" \
       "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}"
} >> "$LOOP_TEST_CALLS"
if [ -x "$LOOP_TEST_CLAUDE_SCRIPT" ]; then
  exec "$LOOP_TEST_CLAUDE_SCRIPT" "$@"
fi
exit 0
CL
chmod +x "$STUB_BIN/claude"

# One canned line per call, driven off a counter file; the last line repeats.
cat > "$STUB_BIN/fake-gate" <<'FG'
#!/bin/bash
n=$(cat "$LOOP_TEST_GATE_COUNT" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$LOOP_TEST_GATE_COUNT"
line=$(sed -n "${n}p" "$LOOP_TEST_GATE_LINES" 2>/dev/null)
[ -z "$line" ] && line=$(tail -1 "$LOOP_TEST_GATE_LINES" 2>/dev/null)
printf '%s\n' "$line"
FG
chmod +x "$STUB_BIN/fake-gate"

cat > "$STUB_BIN/fake-projection" <<'FP'
#!/bin/bash
echo "projection $*" >> "$LOOP_TEST_PROJ_ARGV"
n=$(cat "$LOOP_TEST_PROJ_COUNT" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$LOOP_TEST_PROJ_COUNT"
line=$(sed -n "${n}p" "$LOOP_TEST_PROJ_LINES" 2>/dev/null)
[ -z "$line" ] && line=$(tail -1 "$LOOP_TEST_PROJ_LINES" 2>/dev/null)
printf '%s\n' "$line"
FP
chmod +x "$STUB_BIN/fake-projection"

cat > "$STUB_BIN/fake-sleep" <<'FS'
#!/bin/bash
echo "sleep ${1:-}" >> "$LOOP_TEST_SLEEP_LOG"
exit 0
FS
chmod +x "$STUB_BIN/fake-sleep"

# ---------------------------------------------------------------------------
# Fixtures + assertions
# ---------------------------------------------------------------------------

# write_body <file> <cycle> <step> — the tracker `## Mode` block the wrapper
# parses with the same idioms skills/evolve/SKILL.md `## Durable state` uses.
write_body() {
  cat > "$1" <<BODY
## Mode

\`active\` — cycle $2 · step $3 · issues none · updated 2026-09-07T00:00:00Z

## Runtime
BODY
}

WORK=""
reset_state() { # <slug>
  cat "$CALLS" >> "$ALL_CALLS" 2>/dev/null || true
  : > "$CALLS"
  rm -f "$GATE_COUNT" "$PROJ_COUNT" "$CLAUDE_COUNT" "$CLAUDE_SCRIPT"
  : > "$PROJ_ARGV"
  : > "$SLEEP_LOG"
  printf 'evolve\n' > "$LABELS_FILE"
  write_body "$BODY_FILE" 5 done
  write_body "$BODY_DONE" 5 done
  printf 'usage-gate: decision=proceed five_hour=10%% seven_day=5%% threshold=85 resume_at=--\n' > "$GATE_LINES"
  printf 'PROJECTION decision=proceed est5=30 est7=8 five=10 seven=5 resume_at=--\n' > "$PROJ_LINES"
  WORK="$TMP/work-$1"
  rm -rf "$WORK"
  mkdir -p "$WORK"
}

RC=0
OUT=""
run_helper() {
  OUT="$(cd "$WORK" && PATH="$STUB_BIN:$PATH" \
        EVOLVE_LOOP_USAGE_GATE="$STUB_BIN/fake-gate" \
        EVOLVE_LOOP_PROJECTION="$STUB_BIN/fake-projection" \
        EVOLVE_LOOP_SLEEP_CMD="$STUB_BIN/fake-sleep" \
        PIPELINE_REPO="rjskene/pipeline" \
        ALLOW_ORCHESTRATOR_EDIT="true" \
        timeout 20 bash "$HELPER" "$@" 2>&1)"
  RC=$?
}

expect_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass_msg "$1"; else fail_msg "$1 (missing: $3)"; fi
}
refute_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then
    fail_msg "$1 (unexpectedly present: $3)"
  else
    pass_msg "$1"
  fi
}
expect_rc() { # <label> <want>
  if [ "$RC" -eq "$2" ]; then pass_msg "$1"; else fail_msg "$1 (want rc=$2, got rc=$RC)"; fi
}
expect_eq() { # <label> <actual> <want>
  if [ "${2:-}" = "$3" ]; then pass_msg "$1 ($3)"; else fail_msg "$1 (want $3, got ${2:-<empty>})"; fi
}

count_lines() { # <fixed-substring> <text>
  printf '%s\n' "$2" | grep -cF -- "$1" 2>/dev/null || true
}
count_file() { # <fixed-substring> <file>
  local n
  n="$(grep -cF -- "$1" "$2" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}
counter_of() { # <counter-file>
  cat "$1" 2>/dev/null || echo 0
}
launches() { count_file "claude -p" "$CALLS"; }
sleeps() { count_file "sleep " "$SLEEP_LOG"; }

# ---------------------------------------------------------------------------
scenario "Scenario 1: --dry-run previews exactly one launch and makes NO call"
# ---------------------------------------------------------------------------
reset_state 01
run_helper --dry-run --tracker "$TRACKER_N"

expect_rc "--dry-run exits 0" 0
expect_eq "--dry-run prints exactly one LOOP-LAUNCH line" "$(count_lines 'LOOP-LAUNCH ' "$OUT")" 1
expect_sub "launch line marks the session headless" "$OUT" "PIPELINE_HEADLESS=true"
expect_sub "launch line disables the print-mode background wait ceiling" "$OUT" "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0"
expect_sub "launch line runs claude in print mode" "$OUT" "claude -p"
expect_sub "launch line points --plugin-dir at the clone" "$OUT" "--plugin-dir $ROOT"
expect_sub "launch line skips permission prompts" "$OUT" "--dangerously-skip-permissions"

if [ -s "$CALLS" ]; then
  fail_msg "--dry-run made no gh/claude call (call log: $(tr '\n' '|' < "$CALLS"))"
else
  pass_msg "--dry-run made no gh/claude call"
fi
expect_eq "--dry-run never ran the usage gate" "$(counter_of "$GATE_COUNT")" 0
expect_eq "--dry-run never ran the projection" "$(counter_of "$PROJ_COUNT")" 0

# ---------------------------------------------------------------------------
scenario "Scenario 2: Mode 'step done' launches /pipeline:evolve start"
# ---------------------------------------------------------------------------
reset_state 02
write_body "$BODY_FILE" 5 done
run_helper --cycles 1 --tracker "$TRACKER_N"

expect_rc "a completed cycle exits 0" 0
expect_sub "recorded claude argv carries the start command" "$(cat "$CALLS")" "/pipeline:evolve start --cycles 1"
expect_sub "the launched session is marked headless" "$(cat "$CALLS")" "PIPELINE_HEADLESS=true"
expect_sub "the launched session does not inherit ALLOW_ORCHESTRATOR_EDIT" "$(cat "$CALLS")" "ALLOW_ORCHESTRATOR_EDIT=unset"

# ---------------------------------------------------------------------------
scenario "Scenario 3: Mode 'step 4' launches /pipeline:evolve resume"
# ---------------------------------------------------------------------------
reset_state 03
write_body "$BODY_FILE" 5 4
run_helper --cycles 1 --max-resumes 0 --tracker "$TRACKER_N"

expect_sub "recorded claude argv carries the resume command" "$(cat "$CALLS")" "/pipeline:evolve resume"
refute_sub "a mid-cycle step never launches start" "$(cat "$CALLS")" "/pipeline:evolve start"

# ---------------------------------------------------------------------------
scenario "Scenario 4: the 'paused' label is the operator kill switch"
# ---------------------------------------------------------------------------
reset_state 04
printf 'evolve\npaused\n' > "$LABELS_FILE"
run_helper --cycles 1 --tracker "$TRACKER_N"

expect_rc "paused exits 0" 0
expect_sub "paused reports its reason" "$OUT" "LOOP-STOP reason=paused"
refute_sub "paused launches nothing" "$(cat "$CALLS")" "claude -p"
expect_eq "paused never runs the usage gate" "$(counter_of "$GATE_COUNT")" 0
expect_eq "paused never runs the projection" "$(counter_of "$PROJ_COUNT")" 0

# ---------------------------------------------------------------------------
scenario "Scenario 5: a projected pause-5h sleeps, re-checks, then launches"
# ---------------------------------------------------------------------------
reset_state 05
{
  printf 'PROJECTION decision=pause-5h est5=30 est7=8 five=80 seven=20 resume_at=%s\n' "$FUTURE"
  printf 'PROJECTION decision=proceed est5=30 est7=8 five=10 seven=5 resume_at=--\n'
} > "$PROJ_LINES"
T0=$(date +%s)
run_helper --cycles 1 --tracker "$TRACKER_N"
T1=$(date +%s)

expect_rc "the loop completes after the pause" 0
expect_eq "the sleep seam is invoked exactly once" "$(sleeps)" 1
SECS5="$(sed -nE 's/^sleep ([0-9]+)$/\1/p' "$SLEEP_LOG" | head -1)"
if [ -n "$SECS5" ] && [ "$SECS5" -gt 0 ] 2>/dev/null; then
  pass_msg "the sleep seam is handed a positive integer ($SECS5)"
else
  fail_msg "the sleep seam is handed a positive integer (got: ${SECS5:-<none>})"
fi
expect_eq "the projection is consulted on both iterations" "$(counter_of "$PROJ_COUNT")" 2
expect_eq "exactly one session is launched" "$(launches)" 1
if [ $((T1 - T0)) -lt 10 ]; then
  pass_msg "the pause costs no wall time (seam, not a real sleep)"
else
  fail_msg "the pause costs no wall time (elapsed $((T1 - T0))s)"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 6: halt-7d stops the loop with rc 3 and launches nothing"
# ---------------------------------------------------------------------------
reset_state 06
printf 'PROJECTION decision=halt-7d est5=30 est7=8 five=40 seven=91 resume_at=--\n' > "$PROJ_LINES"
run_helper --cycles 1 --tracker "$TRACKER_N"

expect_rc "halt-7d exits 3" 3
expect_sub "halt-7d reports its reason" "$OUT" "LOOP-STOP reason=halt-7d"
expect_sub "halt-7d reports the seven-day percentage" "$OUT" "seven=91"
refute_sub "halt-7d launches nothing" "$(cat "$CALLS")" "claude -p"

# ---------------------------------------------------------------------------
scenario "Scenario 7: the PROJECTION line, not the raw gate line, decides"
# ---------------------------------------------------------------------------
reset_state 07
GATE_TEXT="usage-gate: decision=proceed five_hour=70% seven_day=60% threshold=85 resume_at=--"
printf '%s\n' "$GATE_TEXT" > "$GATE_LINES"
{
  printf 'PROJECTION decision=pause-5h est5=30 est7=8 five=70 seven=60 resume_at=%s\n' "$FUTURE"
  printf 'PROJECTION decision=halt-7d est5=30 est7=8 five=70 seven=91 resume_at=--\n'
} > "$PROJ_LINES"
run_helper --cycles 1 --tracker "$TRACKER_N"

expect_eq "a gate 'proceed' flipped to pause-5h still sleeps" "$(sleeps)" 1
refute_sub "a projected pause launches nothing despite gate=proceed" "$(cat "$CALLS")" "claude -p"
expect_sub "the projection is passed the tracker" "$(cat "$PROJ_ARGV")" "--tracker $TRACKER_N"
expect_sub "the projection is passed the gate's own line" "$(cat "$PROJ_ARGV")" "--gate-line $GATE_TEXT"
expect_rc "the second iteration's halt-7d still exits 3" 3

# ---------------------------------------------------------------------------
scenario "Scenario 8: a headless usage-pause exit costs no cycle and no resume"
# ---------------------------------------------------------------------------
# Call 1 prints the skill's headless usage-pause token and leaves Mode at
# `step 4`; call 2 prints nothing and advances Mode to `step done`. The pause
# must be slept out and relaunched, and — the round-4 pin — classified from the
# CURRENT launch's log only, so exactly ONE pause classification is emitted.
reset_state 08
write_body "$BODY_FILE" 5 4
write_body "$BODY_DONE" 5 done
export LOOP_TEST_RESUME_AT="$FUTURE"
cat > "$CLAUDE_SCRIPT" <<'S8'
#!/bin/bash
n=$(cat "$LOOP_TEST_CLAUDE_COUNT" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$LOOP_TEST_CLAUDE_COUNT"
if [ "$n" -eq 1 ]; then
  echo "HEADLESS-DEFAULT: usage-pause decision=exit-for-wrapper reason=wrapper-owns-the-sleep resume_at=$LOOP_TEST_RESUME_AT"
else
  cat "$LOOP_TEST_BODY_DONE" > "$LOOP_TEST_BODY"
fi
exit 0
S8
chmod +x "$CLAUDE_SCRIPT"
run_helper --cycles 1 --max-resumes 0 --tracker "$TRACKER_N"

expect_sub "the headless pause is classified as such" "$OUT" "LOOP-PAUSE reason=headless-exit"
expect_eq "the pause is classified EXACTLY once (current launch's log only)" "$(count_lines 'LOOP-PAUSE reason=headless-exit' "$OUT")" 1
expect_eq "the sleep seam is invoked exactly once" "$(sleeps)" 1
expect_eq "exactly two sessions are launched" "$(launches)" 2
expect_sub "the cycle still completes" "$OUT" "LOOP-STOP reason=cycles-complete"
expect_rc "a paused-then-completed cycle exits 0" 0
if [ "$RC" -eq 124 ]; then
  fail_msg "the loop is bounded (rc 124 = runaway relaunch)"
else
  pass_msg "the loop is bounded (rc != 124)"
fi
unset LOOP_TEST_RESUME_AT
export LOOP_TEST_RESUME_AT="--"

# ---------------------------------------------------------------------------
scenario "Scenario 8b: an UNEXPLAINED exit does consume a resume"
# ---------------------------------------------------------------------------
reset_state 08b
write_body "$BODY_FILE" 5 4
run_helper --cycles 1 --max-resumes 0 --tracker "$TRACKER_N"

expect_rc "an exhausted resume budget exits 4" 4
expect_sub "the resume cap reports its reason" "$OUT" "LOOP-STOP reason=resume-cap"
expect_eq "exactly one session is launched" "$(launches)" 1
refute_sub "an unexplained exit is not a pause" "$OUT" "LOOP-PAUSE reason=headless-exit"

# ---------------------------------------------------------------------------
scenario "Scenario 8c: consecutive headless pauses are bounded by --max-pauses"
# ---------------------------------------------------------------------------
reset_state 08c
write_body "$BODY_FILE" 5 4
export LOOP_TEST_RESUME_AT="$FUTURE"
cat > "$CLAUDE_SCRIPT" <<'S8C'
#!/bin/bash
echo "HEADLESS-DEFAULT: usage-pause decision=exit-for-wrapper reason=wrapper-owns-the-sleep resume_at=$LOOP_TEST_RESUME_AT"
exit 0
S8C
chmod +x "$CLAUDE_SCRIPT"
run_helper --max-pauses 2 --max-resumes 0 --tracker "$TRACKER_N"

expect_eq "one launch plus exactly two permitted pauses" "$(launches)" 3
expect_eq "the sleep seam is invoked exactly twice" "$(sleeps)" 2
expect_sub "the pause cap reports its reason" "$OUT" "LOOP-STOP reason=pause-cap"
expect_rc "the pause cap exits 5" 5
if [ "$RC" -eq 124 ]; then
  fail_msg "an always-pausing session cannot relaunch forever (rc 124)"
else
  pass_msg "an always-pausing session cannot relaunch forever (rc != 124)"
fi
unset LOOP_TEST_RESUME_AT
export LOOP_TEST_RESUME_AT="--"

# ---------------------------------------------------------------------------
scenario "Scenario 9: a Mode that never advances is capped by --max-resumes"
# ---------------------------------------------------------------------------
reset_state 09
write_body "$BODY_FILE" 5 4
run_helper --max-resumes 2 --tracker "$TRACKER_N"

expect_eq "one launch plus exactly two resumes" "$(launches)" 3
expect_sub "the resume cap reports its reason" "$OUT" "LOOP-STOP reason=resume-cap"
expect_rc "the resume cap exits 4" 4

# ---------------------------------------------------------------------------
scenario "Scenario 10: each launch leaves its OWN log file"
# ---------------------------------------------------------------------------
reset_state 10
write_body "$BODY_FILE" 5 done
write_body "$BODY_DONE" 5 done
cat > "$CLAUDE_SCRIPT" <<'S10'
#!/bin/bash
cat "$LOOP_TEST_BODY_DONE" > "$LOOP_TEST_BODY"
exit 0
S10
chmod +x "$CLAUDE_SCRIPT"
run_helper --cycles 2 --tracker "$TRACKER_N"

expect_rc "two completed cycles exit 0" 0
expect_sub "the cycle budget is reported" "$OUT" "LOOP-STOP reason=cycles-complete"
expect_eq "exactly two sessions are launched" "$(launches)" 2
LOG_DIR_10="$WORK/.claude/scratch/evolve-loop"
LOG_COUNT="$(find "$LOG_DIR_10" -maxdepth 1 -name 'cycle-*.log' 2>/dev/null | wc -l | tr -d ' ')"
expect_eq "two DISTINCT per-launch log files (the -<seq> suffix differs)" "$LOG_COUNT" 2

# ---------------------------------------------------------------------------
scenario "Scenario 11: the sleep interval is clamped both ways"
# ---------------------------------------------------------------------------
clamp_case() { # <slug> <resume_at> <want-secs>
  reset_state "11-$1"
  {
    printf 'PROJECTION decision=pause-5h est5=30 est7=8 five=70 seven=60 resume_at=%s\n' "$2"
    printf 'PROJECTION decision=halt-7d est5=30 est7=8 five=70 seven=91 resume_at=--\n'
  } > "$PROJ_LINES"
  run_helper --cycles 1 --tracker "$TRACKER_N"
  expect_eq "resume_at=$2 sleeps $3s" "$(sed -nE 's/^sleep (-?[0-9]+)$/\1/p' "$SLEEP_LOG" | head -1)" "$3"
}
clamp_case far "3000-01-01T00:00:00Z" 21600
clamp_case sentinel "--" 300
clamp_case past "2000-01-01T00:00:00Z" 60

# ---------------------------------------------------------------------------
scenario "Scenario 12: a value-taking flag in LAST position is a usage error"
# ---------------------------------------------------------------------------
# Without a require_value guard, `shift 2` with $#=1 fails, the token is never
# consumed, and the parser spins forever — run_helper's `timeout 20` would then
# report rc 124 instead of a clean rc 2.
reset_state 12
for flag in --cycles --max-pauses --max-resumes --tracker --timeout --model; do
  run_helper --dry-run "$flag"
  expect_rc "$flag in last position exits 2" 2
  expect_sub "$flag in last position names itself" "$OUT" "$flag requires a value"
done

run_helper --bogus
expect_rc "an unknown flag exits 2" 2
expect_sub "an unknown flag names itself" "$OUT" "--bogus"

# ---------------------------------------------------------------------------
scenario "Scenario 13: comment-trust control — no --json comments, ever"
# ---------------------------------------------------------------------------
cat "$CALLS" >> "$ALL_CALLS" 2>/dev/null || true
if [ -s "$ALL_CALLS" ]; then
  pass_msg "the aggregate call log is non-empty (the control is not vacuous)"
else
  fail_msg "the aggregate call log is EMPTY — nothing was recorded to check"
fi
refute_sub "no scenario ever read issue comments" "$(cat "$ALL_CALLS")" "--json comments"
expect_sub "the wrapper reads tracker labels" "$(cat "$ALL_CALLS")" "--json labels"
expect_sub "the wrapper reads the tracker body" "$(cat "$ALL_CALLS")" "--json body"

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
