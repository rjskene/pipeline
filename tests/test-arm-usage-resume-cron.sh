#!/bin/bash
set -uo pipefail
#
# Tests for scripts/arm-usage-resume-cron.sh — DOGFOOD-ONLY deterministic
# spec-emitter for the #969 usage-resume re-check cron (issue #1041).
#
# The emitter prints the EXACT CronCreate arming args to stdout and never
# calls CronCreate (CronCreate/CronList/CronDelete are model-only harness
# tools — only the model arms the cron). This golden test asserts the
# emitted block carries the required tokens, exits 2 on a missing required
# arg, and contains NO ScheduleWakeup / one-shot wakeup language (R2/R3).
#
# Also guards the hardened `## Usage gate (#969)` prose in
# skills/fullsend/SKILL.md so a regression back to hand-reconstructed cron
# args fails CI.
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/arm-usage-resume-cron.sh"
SKILL="$REPO_ROOT/skills/fullsend/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

# run_emit <args...> — run the emitter, capture stdout/$OUT, stderr/$ERR,
# exit code/$RC.
run_emit() {
  OUT="$(bash "$HELPER" "$@" 2>"$REPO_ROOT/.arm-cron-err.$$")"
  RC=$?
  ERR="$(cat "$REPO_ROOT/.arm-cron-err.$$" 2>/dev/null || true)"
  rm -f "$REPO_ROOT/.arm-cron-err.$$"
}

# assert_contains <label> <substring> — $OUT contains the literal substring.
assert_contains() {
  local label="$1" needle="$2"
  if printf '%s' "$OUT" | grep -qF "$needle"; then
    pass_msg "$label: output contains \"$needle\""
  else
    fail_msg "$label: missing \"$needle\" (got: $OUT)"
  fi
}

# Fixed happy-path inputs.
RESUME_CMD="/pipeline:fullsend 1041 1042 --campaign"
RESUME_AT="2026-06-13T18:05Z"

# --- Scenario 1: scaffolding (existence + executable + --help banner) ---
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/arm-usage-resume-cron.sh"
else
  fail_msg "script file missing at scripts/arm-usage-resume-cron.sh"
fi

if [ -x "$HELPER" ]; then
  pass_msg "script is executable"
else
  fail_msg "script is NOT executable"
fi

HELP_OUT="$(bash "$HELPER" --help 2>&1)"; HELP_RC=$?
if [ "$HELP_RC" -eq 0 ]; then
  pass_msg "--help exits 0"
else
  fail_msg "--help exited non-zero (rc=$HELP_RC)"
fi
if printf '%s' "$HELP_OUT" | grep -q 'arm-usage-resume'; then
  pass_msg "--help prints arm-usage-resume banner"
else
  fail_msg "--help missing arm-usage-resume banner"
fi

# --- Scenario 2: happy path emits the full CronCreate arming block ---
inc_scenario "Scenario 2: happy path -> RC=0, full arming block"

run_emit --resume-command "$RESUME_CMD" --resume-at "$RESUME_AT"
if [ "$RC" -eq 0 ]; then
  pass_msg "happy path: exit 0"
else
  fail_msg "happy path: expected exit 0, got rc=$RC (err: $ERR)"
fi

assert_contains "happy" "13,38 * * * *"
assert_contains "happy" "usage-resume re-check"
assert_contains "happy" "$RESUME_CMD"
assert_contains "happy" "$RESUME_AT"
assert_contains "happy" "scripts/usage-gate.sh"
assert_contains "happy" "delete the usage-resume cron if present"

# CronCreate-shaped block: schedule:, marker:, prompt: fields.
assert_contains "happy" "schedule:"
assert_contains "happy" "marker:"
assert_contains "happy" "prompt:"

# --- Scenario 3: NEGATIVE — no ScheduleWakeup / one-shot (R2/R3) ---
inc_scenario "Scenario 3: negative -> no ScheduleWakeup / one-shot"

SW_COUNT="$(printf '%s' "$OUT" | grep -c 'ScheduleWakeup' || true)"
if [ "$SW_COUNT" -eq 0 ]; then
  pass_msg "output contains NO ScheduleWakeup"
else
  fail_msg "output contains ScheduleWakeup ($SW_COUNT occurrence(s))"
fi

OS_COUNT="$(printf '%s' "$OUT" | grep -ic 'one-shot' || true)"
if [ "$OS_COUNT" -eq 0 ]; then
  pass_msg "output contains NO one-shot (case-insensitive)"
else
  fail_msg "output contains one-shot ($OS_COUNT occurrence(s))"
fi

# --- Scenario 4: missing required arg -> RC=2 ---
inc_scenario "Scenario 4: missing required arg -> RC=2"

run_emit --resume-command "$RESUME_CMD"
if [ "$RC" -eq 2 ]; then
  pass_msg "missing --resume-at: exit 2"
else
  fail_msg "missing --resume-at: expected exit 2, got rc=$RC"
fi

run_emit --resume-at "$RESUME_AT"
if [ "$RC" -eq 2 ]; then
  pass_msg "missing --resume-command: exit 2"
else
  fail_msg "missing --resume-command: expected exit 2, got rc=$RC"
fi

# --- Scenario 5: SKILL-prose guard for hardened ## Usage gate (#969) ---
inc_scenario "Scenario 5: ## Usage gate (#969) prose hardening"

# Extract ONLY the `## Usage gate (#969)` section body (heading to next `## `).
GATE_SECTION="$(awk '
  /^## Usage gate \(#969\)/ { inside=1; next }
  inside && /^## / { inside=0 }
  inside { print }
' "$SKILL")"

if printf '%s' "$GATE_SECTION" | grep -qF "arm-usage-resume-cron.sh"; then
  pass_msg "section references arm-usage-resume-cron.sh (no hand-reconstruction)"
else
  fail_msg "section does NOT reference arm-usage-resume-cron.sh"
fi

if printf '%s' "$GATE_SECTION" | grep -q "ScheduleWakeup"; then
  pass_msg "section contains an explicit ScheduleWakeup ban reference"
else
  fail_msg "section missing ScheduleWakeup ban reference"
fi

# Red-flag callout markers: auto-resume-is-default + never-stop-and-ask.
if printf '%s' "$GATE_SECTION" | grep -qi "DEFAULT"; then
  pass_msg "section contains auto-resume-is-DEFAULT phrasing"
else
  fail_msg "section missing auto-resume-is-DEFAULT phrasing"
fi

if printf '%s' "$GATE_SECTION" | grep -qi "stop-and-ask"; then
  pass_msg "section contains never-stop-and-ask phrasing"
else
  fail_msg "section missing never-stop-and-ask phrasing"
fi

# --- Scenario 6: generic --resume-command banner (not fullsend-specific) ---
inc_scenario "Scenario 6: generic --resume-command banner + evolve pass-through"

HELP6="$(bash "$HELPER" --help 2>&1)"

if grep -qF '/pipeline:evolve resume' <<<"$HELP6"; then
  pass_msg "banner: --help carries an evolve resume example"
else
  fail_msg "banner: --help missing an evolve resume example (/pipeline:evolve resume)"
fi

if grep -qF 'resume command' <<<"$HELP6"; then
  pass_msg "banner: --help uses the generic phrase \"resume command\""
else
  fail_msg "banner: --help missing the generic phrase \"resume command\""
fi

if [ "$(grep -cF 'The verbatim /pipeline:fullsend command' <<<"$HELP6")" -eq 0 ]; then
  pass_msg "banner: fullsend-only wording is gone"
else
  fail_msg "banner: --help still carries fullsend-only wording (\"The verbatim /pipeline:fullsend command\")"
fi

# CONTROL: the emitter already passes any resume command through verbatim.
run_emit --resume-command "/pipeline:evolve resume" --resume-at "$RESUME_AT"
if [ "$RC" -eq 0 ]; then
  pass_msg "evolve pass-through: exit 0"
else
  fail_msg "evolve pass-through: expected exit 0, got rc=$RC (err: $ERR)"
fi
assert_contains "evolve pass-through" "/pipeline:evolve resume"

# --- Summary ---
echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
