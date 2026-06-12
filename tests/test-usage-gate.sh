#!/bin/bash
set -uo pipefail
#
# Tests for scripts/usage-gate.sh — usage-aware pause/resume gate (issue #969).
#
# Pure reader + decision over the OAuth usage endpoint
# (https://api.anthropic.com/api/oauth/usage). Emits exactly ONE stdout line
#   usage-gate: decision=<tok>[ reason=<r>] five_hour=<N%|--> seven_day=<N%|--> threshold=<N> resume_at=<ISO|-->
# and ALWAYS exits 0 (fail-open; never gate-fatal).
#
# Fixture-driven via --fixture/--now/--threshold/--credentials; no live network.
# Fixtures live in tests/fixtures/usage-gate/ (probe-evidence shape, spec
# docs/superpowers/specs/2026-06-10-usage-gate-design.md §Signal).
#
# Token-leak canary: a fake bearer token planted in the test creds file must
# NEVER appear on stdout or stderr in any mode.
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/usage-gate.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/usage-gate"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

# Isolate from any operator env (pipeline.config may set these).
unset PIPELINE_USAGE_GATE_ENABLED PIPELINE_USAGE_GATE_THRESHOLD_PCT

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CANARY_TOKEN="sk-ant-oat01-FAKE-CANARY-969"
CREDS="$TMP/creds.json"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$CANARY_TOKEN" > "$CREDS"

NOW="2026-06-10T18:00:00Z"

# run_gate <extra args...> — runs the helper with the canary creds file,
# capturing stdout into $OUT, stderr into $ERR, exit code into $RC.
# Every stdout+stderr byte is also appended to the canary transcript.
CANARY_TRANSCRIPT="$TMP/canary-transcript.txt"
run_gate() {
  OUT="$(bash "$HELPER" "$@" 2>"$TMP/err.txt")"
  RC=$?
  ERR="$(cat "$TMP/err.txt")"
  { printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
}

# assert_gate_line <label> — $OUT is exactly ONE line starting "usage-gate: "
# and $RC is 0 (the two hard invariants, asserted in every scenario).
assert_gate_line() {
  local label="$1"
  if [ "$RC" -eq 0 ]; then
    pass_msg "$label: exit 0"
  else
    fail_msg "$label: expected exit 0, got rc=$RC"
  fi
  local n
  n="$(printf '%s\n' "$OUT" | grep -c '^usage-gate: ')"
  local total
  total="$(printf '%s\n' "$OUT" | wc -l)"
  if [ "$n" -eq 1 ] && [ "$total" -eq 1 ]; then
    pass_msg "$label: exactly one usage-gate stdout line"
  else
    fail_msg "$label: expected exactly one usage-gate stdout line (got $total line(s): $OUT)"
  fi
}

# assert_field <label> <pattern> — $OUT contains the literal field token.
assert_field() {
  local label="$1" pattern="$2"
  if printf '%s' "$OUT" | grep -qF "$pattern"; then
    pass_msg "$label: line contains $pattern"
  else
    fail_msg "$label: missing $pattern (got: $OUT)"
  fi
}

# --- Scenario 1: scaffolding (existence + executable + --help banner) ---
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/usage-gate.sh"
else
  fail_msg "script file missing at scripts/usage-gate.sh"
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
if printf '%s' "$HELP_OUT" | grep -q 'usage-gate'; then
  pass_msg "--help prints usage-gate banner"
else
  fail_msg "--help missing usage-gate banner"
fi

# --- Scenario 2: under threshold -> proceed ---
inc_scenario "Scenario 2: under threshold -> decision=proceed"

run_gate --fixture "$FIXTURE_DIR/under-threshold.json" --now "$NOW" --credentials "$CREDS"
assert_gate_line "proceed"
assert_field "proceed" "decision=proceed"
assert_field "proceed" "five_hour=20%"
assert_field "proceed" "seven_day=27%"
assert_field "proceed" "threshold=85"
assert_field "proceed" "resume_at=--"

# --- Scenario 3: five_hour over -> pause-5h with exact resume_at ---
inc_scenario "Scenario 3: five_hour over -> decision=pause-5h, resume_at = resets_at + 5 min"

run_gate --fixture "$FIXTURE_DIR/five-hour-over.json" --now "$NOW" --credentials "$CREDS"
assert_gate_line "pause-5h"
assert_field "pause-5h" "decision=pause-5h"
assert_field "pause-5h" "five_hour=91%"
assert_field "pause-5h" "seven_day=40%"
# Exact arithmetic: resets_at 2026-06-10T20:59:59+00:00 + 5 min.
assert_field "pause-5h" "resume_at=2026-06-10T21:04:59Z"

# --- Scenario 4: seven_day over -> halt-7d, never auto-resume ---
inc_scenario "Scenario 4: seven_day over -> decision=halt-7d"

run_gate --fixture "$FIXTURE_DIR/seven-day-over.json" --now "$NOW" --credentials "$CREDS"
assert_gate_line "halt-7d"
assert_field "halt-7d" "decision=halt-7d"
assert_field "halt-7d" "five_hour=12%"
assert_field "halt-7d" "seven_day=93%"
assert_field "halt-7d" "resume_at=--"

# --- Scenario 5: BOTH over -> halt-7d wins ---
inc_scenario "Scenario 5: both windows over -> halt-7d wins"

run_gate --fixture "$FIXTURE_DIR/both-over.json" --now "$NOW" --credentials "$CREDS"
assert_gate_line "both-over"
assert_field "both-over" "decision=halt-7d"
assert_field "both-over" "resume_at=--"

# --- Scenario 6: threshold boundary (== trips, >=) ---
inc_scenario "Scenario 6: utilization == threshold trips (>=)"

run_gate --fixture "$FIXTURE_DIR/boundary-equal.json" --now "$NOW" --credentials "$CREDS"
assert_gate_line "boundary"
assert_field "boundary" "decision=pause-5h"
assert_field "boundary" "five_hour=85%"

# --- Scenario 7: --threshold override ---
inc_scenario "Scenario 7: --threshold override honored"

# 7a: override rendered in the line.
run_gate --fixture "$FIXTURE_DIR/under-threshold.json" --now "$NOW" --credentials "$CREDS" --threshold 50
assert_gate_line "threshold-50"
assert_field "threshold-50" "threshold=50"
assert_field "threshold-50" "decision=proceed"

# 7b: override changes the decision (7d 27 >= 15 -> halt-7d).
run_gate --fixture "$FIXTURE_DIR/under-threshold.json" --now "$NOW" --credentials "$CREDS" --threshold 15
assert_gate_line "threshold-15"
assert_field "threshold-15" "decision=halt-7d"
assert_field "threshold-15" "threshold=15"

# 7c: env var PIPELINE_USAGE_GATE_THRESHOLD_PCT honored when no flag.
OUT="$(PIPELINE_USAGE_GATE_THRESHOLD_PCT=15 bash "$HELPER" --fixture "$FIXTURE_DIR/under-threshold.json" --now "$NOW" --credentials "$CREDS" 2>"$TMP/err.txt")"
RC=$?
ERR="$(cat "$TMP/err.txt")"
{ printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
assert_gate_line "env-threshold"
assert_field "env-threshold" "decision=halt-7d"
assert_field "env-threshold" "threshold=15"

# --- Scenario 8: kill switch -> skip reason=disabled ---
inc_scenario "Scenario 8: PIPELINE_USAGE_GATE_ENABLED=false -> skip reason=disabled"

OUT="$(PIPELINE_USAGE_GATE_ENABLED=false bash "$HELPER" --fixture "$FIXTURE_DIR/under-threshold.json" --now "$NOW" --credentials "$CREDS" 2>"$TMP/err.txt")"
RC=$?
ERR="$(cat "$TMP/err.txt")"
{ printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
assert_gate_line "disabled"
assert_field "disabled" "decision=skip reason=disabled"
assert_field "disabled" "five_hour=--"
assert_field "disabled" "seven_day=--"
assert_field "disabled" "resume_at=--"

# --- Scenario 9: missing creds -> skip reason=no-credentials ---
inc_scenario "Scenario 9: missing/tokenless creds -> skip reason=no-credentials"

# 9a: creds file absent.
run_gate --fixture "$FIXTURE_DIR/under-threshold.json" --now "$NOW" --credentials "/nonexistent/creds.json"
assert_gate_line "no-creds-file"
assert_field "no-creds-file" "decision=skip reason=no-credentials"

# 9b: creds file present but no .claudeAiOauth.accessToken.
printf '{"someOtherKey":{"foo":"bar"}}\n' > "$TMP/tokenless-creds.json"
run_gate --fixture "$FIXTURE_DIR/under-threshold.json" --now "$NOW" --credentials "$TMP/tokenless-creds.json"
assert_gate_line "tokenless-creds"
assert_field "tokenless-creds" "decision=skip reason=no-credentials"

# 9c: HOME unset (headless cron resume) must not abort under set -u — the
# default-creds path degrades to skip reason=no-credentials, exit 0.
OUT="$(env -u HOME bash "$HELPER" --fixture "$FIXTURE_DIR/under-threshold.json" --now "$NOW" 2>"$TMP/err.txt")"
RC=$?
ERR="$(cat "$TMP/err.txt")"
{ printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
assert_gate_line "home-unset"
assert_field "home-unset" "decision=skip reason=no-credentials"

# --- Scenario 10: malformed body -> skip reason=parse-error ---
inc_scenario "Scenario 10: malformed fixture -> skip reason=parse-error"

run_gate --fixture "$FIXTURE_DIR/malformed.json" --now "$NOW" --credentials "$CREDS"
assert_gate_line "malformed"
assert_field "malformed" "decision=skip reason=parse-error"
assert_field "malformed" "resume_at=--"

# --- Scenario 11: live-fetch error mapping via PATH-stubbed curl ---
inc_scenario "Scenario 11: live fetch (PATH-stubbed curl) -> http-<code>/fetch-error/proceed"

mkdir -p "$TMP/bin"
CURL_ARGV_LOG="$TMP/curl-argv.log"

# write_curl_stub <body-of-stub> — installs $TMP/bin/curl that logs its argv
# (so the test can prove the bearer token never reaches process argv), drains
# stdin (the --config - payload), then runs the case-specific behavior.
write_curl_stub() {
  cat > "$TMP/bin/curl" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >> "$CURL_ARGV_LOG"
# locate the -o target
OUT_TARGET=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && OUT_TARGET="\$a"
  prev="\$a"
done
cat > /dev/null  # drain stdin (--config -)
$1
STUB
  chmod +x "$TMP/bin/curl"
}

# run_gate_live <label> — run with NO --fixture and the stub curl on PATH.
run_gate_live() {
  OUT="$(PATH="$TMP/bin:$PATH" bash "$HELPER" --now "$NOW" --credentials "$CREDS" 2>"$TMP/err.txt")"
  RC=$?
  ERR="$(cat "$TMP/err.txt")"
  { printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
}

# 12a: HTTP 429 -> skip reason=http-429.
write_curl_stub '[ -n "$OUT_TARGET" ] && printf "{}" > "$OUT_TARGET"
printf "429"
exit 0'
run_gate_live
assert_gate_line "http-429"
assert_field "http-429" "decision=skip reason=http-429"

# 12b: curl hard failure (rc=7) -> skip reason=fetch-error.
write_curl_stub 'exit 7'
run_gate_live
assert_gate_line "fetch-error"
assert_field "fetch-error" "decision=skip reason=fetch-error"

# 12c: HTTP 200 + valid body -> live path parses the same shape -> proceed.
write_curl_stub "[ -n \"\$OUT_TARGET\" ] && cat \"$FIXTURE_DIR/under-threshold.json\" > \"\$OUT_TARGET\"
printf \"200\"
exit 0"
run_gate_live
assert_gate_line "live-200"
assert_field "live-200" "decision=proceed"
assert_field "live-200" "five_hour=20%"
assert_field "live-200" "seven_day=27%"

# 12d: bearer token never reaches curl argv (passed via --config on stdin).
if [ -s "$CURL_ARGV_LOG" ]; then
  pass_msg "curl stub captured argv across live modes"
else
  fail_msg "curl argv log empty — argv canary would be vacuous"
fi
if grep -qF "$CANARY_TOKEN" "$CURL_ARGV_LOG"; then
  fail_msg "BEARER TOKEN visible on curl argv (would leak via /proc/*/cmdline)"
else
  pass_msg "bearer token absent from curl argv (stdin --config holds it)"
fi

# --- Scenario 12: token-leak canary (all modes above) ---
inc_scenario "Scenario 12: token-leak canary across all exercised modes"

if [ -s "$CANARY_TRANSCRIPT" ]; then
  pass_msg "canary transcript captured stdout+stderr across all modes"
else
  fail_msg "canary transcript is empty — canary grep would be vacuous"
fi
if grep -qF "$CANARY_TOKEN" "$CANARY_TRANSCRIPT"; then
  fail_msg "BEARER TOKEN LEAKED into stdout/stderr (canary found in transcript)"
else
  pass_msg "bearer token never appears in stdout/stderr (canary absent)"
fi

# --- Scenario 15: PIPELINE_LOGS_ENABLED=true -> one valid JSONL breadcrumb ---
# (#1016 R6) Numbering starts at 15: scenarios 13/14 are the SKILL.md prose
# guards below; the new breadcrumb scenarios slot in here, before them.
inc_scenario "Scenario 15: logs enabled -> exactly one valid JSONL breadcrumb; decision line unchanged"
LOGROOT="$TMP/logroot"; mkdir -p "$LOGROOT"
LOGFILE="$LOGROOT/.claude/logs/usage-gate.jsonl"
OUT="$(PIPELINE_LOGS_ENABLED=true PIPELINE_PROJECT_ROOT="$LOGROOT" bash "$HELPER" \
  --fixture "$FIXTURE_DIR/five-hour-over.json" --now "$NOW" --credentials "$CREDS" 2>"$TMP/err.txt")"
RC=$?
ERR="$(cat "$TMP/err.txt")"
{ printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
assert_gate_line "breadcrumb-enabled"
assert_field "breadcrumb-enabled" "decision=pause-5h"
if [ -f "$LOGFILE" ]; then pass_msg "breadcrumb-enabled: log file created"; else fail_msg "breadcrumb-enabled: log file NOT created"; fi
LINES="$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)"
if [ "$LINES" -eq 1 ]; then pass_msg "breadcrumb-enabled: exactly one JSONL line"; else fail_msg "breadcrumb-enabled: expected 1 line, got $LINES"; fi
if jq -e . "$LOGFILE" >/dev/null 2>&1; then pass_msg "breadcrumb-enabled: line is valid JSON"; else fail_msg "breadcrumb-enabled: line is NOT valid JSON ($(cat "$LOGFILE" 2>/dev/null))"; fi
if [ "$(jq -r '.decision' "$LOGFILE" 2>/dev/null)" = "pause-5h" ]; then pass_msg "breadcrumb-enabled: .decision=pause-5h"; else fail_msg "breadcrumb-enabled: .decision mismatch"; fi
if [ "$(jq -r '.five_hour' "$LOGFILE" 2>/dev/null)" = "91%" ]; then pass_msg "breadcrumb-enabled: .five_hour=91%"; else fail_msg "breadcrumb-enabled: .five_hour mismatch"; fi
if [ "$(jq -r '.resume_at' "$LOGFILE" 2>/dev/null)" = "2026-06-10T21:04:59Z" ]; then pass_msg "breadcrumb-enabled: .resume_at matches gate line"; else fail_msg "breadcrumb-enabled: .resume_at mismatch"; fi
for f in ts decision reason five_hour seven_day threshold resume_at; do
  if jq -e "has(\"$f\")" "$LOGFILE" >/dev/null 2>&1; then pass_msg "breadcrumb-enabled: field $f present"; else fail_msg "breadcrumb-enabled: field $f MISSING"; fi
done

# --- Scenario 16: logs disabled/unset -> no breadcrumb file written ---
# (#1016 R6 gating regression guard)
inc_scenario "Scenario 16: PIPELINE_LOGS_ENABLED unset/false -> no log file created"
# 16a: unset (default off)
LOGROOT2="$TMP/logroot2"; mkdir -p "$LOGROOT2"
OUT="$(PIPELINE_PROJECT_ROOT="$LOGROOT2" bash "$HELPER" \
  --fixture "$FIXTURE_DIR/five-hour-over.json" --now "$NOW" --credentials "$CREDS" 2>"$TMP/err.txt")"
RC=$?; ERR="$(cat "$TMP/err.txt")"
{ printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
assert_gate_line "logs-unset"
if [ ! -f "$LOGROOT2/.claude/logs/usage-gate.jsonl" ]; then pass_msg "logs-unset: no breadcrumb file"; else fail_msg "logs-unset: breadcrumb file unexpectedly created"; fi
# 16b: explicit false
LOGROOT3="$TMP/logroot3"; mkdir -p "$LOGROOT3"
OUT="$(PIPELINE_LOGS_ENABLED=false PIPELINE_PROJECT_ROOT="$LOGROOT3" bash "$HELPER" \
  --fixture "$FIXTURE_DIR/five-hour-over.json" --now "$NOW" --credentials "$CREDS" 2>"$TMP/err.txt")"
RC=$?; ERR="$(cat "$TMP/err.txt")"
{ printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
assert_gate_line "logs-false"
if [ ! -f "$LOGROOT3/.claude/logs/usage-gate.jsonl" ]; then pass_msg "logs-false: no breadcrumb file"; else fail_msg "logs-false: breadcrumb file unexpectedly created"; fi

# --- Scenario 17: logs enabled but unwritable dir -> decision line intact, exit 0 ---
# (#1016 never-fatal invariant)
inc_scenario "Scenario 17: logs enabled + unwritable logs dir -> still exits 0, single decision line"
UNWRITABLE="$TMP/unwritable"; mkdir -p "$UNWRITABLE/.claude/logs"
# Make .claude/logs itself unwritable so the append fails.
chmod 000 "$UNWRITABLE/.claude/logs"
OUT="$(PIPELINE_LOGS_ENABLED=true PIPELINE_PROJECT_ROOT="$UNWRITABLE" bash "$HELPER" \
  --fixture "$FIXTURE_DIR/five-hour-over.json" --now "$NOW" --credentials "$CREDS" 2>"$TMP/err.txt")"
RC=$?; ERR="$(cat "$TMP/err.txt")"
{ printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } >> "$CANARY_TRANSCRIPT"
chmod 755 "$UNWRITABLE/.claude/logs"  # restore so trap cleanup can rm -rf
assert_gate_line "unwritable-logs"
assert_field "unwritable-logs" "decision=pause-5h"

# --- Scenario 18: token-leak canary extends to the breadcrumb log file (#1016 R6) ---
# Depends on the log-root vars from Scenarios 15-17, so it must follow them.
inc_scenario "Scenario 18: bearer token never lands in usage-gate.jsonl"
LEAK_FOUND=0
for d in "$LOGROOT" "$LOGROOT2" "$LOGROOT3" "$UNWRITABLE"; do
  f="$d/.claude/logs/usage-gate.jsonl"
  [ -f "$f" ] && grep -qF "$CANARY_TOKEN" "$f" && LEAK_FOUND=1
done
if [ "$LEAK_FOUND" -eq 0 ]; then pass_msg "canary absent from all breadcrumb files"; else fail_msg "BEARER TOKEN LEAKED into usage-gate.jsonl"; fi

# --- Scenario 13: fullsend SKILL.md integration (prose guard) ---
inc_scenario "Scenario 13: fullsend SKILL.md wires the gate (prose guard)"

FULLSEND_SKILL="$REPO_ROOT/skills/fullsend/SKILL.md"
GATE_REFS="$(grep -c 'usage-gate.sh' "$FULLSEND_SKILL" 2>/dev/null)"
GATE_REFS="${GATE_REFS:-0}"
if [ "$GATE_REFS" -ge 2 ]; then
  pass_msg "fullsend SKILL references usage-gate.sh >= 2 times (found $GATE_REFS)"
else
  fail_msg "fullsend SKILL needs >= 2 usage-gate.sh references (found $GATE_REFS)"
fi
if grep -q 'pause-5h' "$FULLSEND_SKILL"; then pass_msg "fullsend SKILL handles pause-5h"; else fail_msg "fullsend SKILL missing pause-5h handling"; fi
if grep -q 'halt-7d' "$FULLSEND_SKILL"; then pass_msg "fullsend SKILL handles halt-7d"; else fail_msg "fullsend SKILL missing halt-7d handling"; fi
if grep -q 'CronCreate' "$FULLSEND_SKILL"; then pass_msg "fullsend SKILL schedules resume via CronCreate"; else fail_msg "fullsend SKILL missing CronCreate resume scheduling"; fi

# --- Scenario 19: fullsend arming prose is recurring re-check, not one-shot (#1016) ---
# (#1016 R1-R5) Depends on $FULLSEND_SKILL from Scenario 13, so it follows it.
inc_scenario "Scenario 19: fullsend SKILL arming uses recurring re-check cron contract"
if grep -q 'usage-resume re-check' "$FULLSEND_SKILL"; then pass_msg "fullsend SKILL names the re-check cron marker"; else fail_msg "fullsend SKILL missing 'usage-resume re-check' marker"; fi
if grep -qi 'recurring' "$FULLSEND_SKILL"; then pass_msg "fullsend SKILL describes a recurring cron"; else fail_msg "fullsend SKILL missing 'recurring' arming description"; fi
if grep -q 'CronDelete' "$FULLSEND_SKILL"; then pass_msg "fullsend SKILL deletes the cron on proceed/halt"; else fail_msg "fullsend SKILL missing CronDelete in re-check contract"; fi
if grep -q 'CronList' "$FULLSEND_SKILL"; then pass_msg "fullsend SKILL looks up the cron by marker (CronList)"; else fail_msg "fullsend SKILL missing CronList self-lookup"; fi
if ! grep -q 'ScheduleWakeup' "$FULLSEND_SKILL"; then pass_msg "fullsend SKILL no longer arms via ScheduleWakeup one-shot"; else fail_msg "fullsend SKILL still references the dropped ScheduleWakeup branch"; fi

# --- Scenario 14: status SKILL.md advisory-only relay (prose guard) ---
inc_scenario "Scenario 14: status SKILL.md relays the gate line ADVISORY-only"

STATUS_SKILL="$REPO_ROOT/skills/status/SKILL.md"
if grep -q 'usage-gate.sh' "$STATUS_SKILL"; then
  pass_msg "status SKILL references usage-gate.sh"
else
  fail_msg "status SKILL missing usage-gate.sh reference"
fi
if grep -q 'ADVISORY' "$STATUS_SKILL"; then
  pass_msg "status SKILL marks the gate relay ADVISORY"
else
  fail_msg "status SKILL missing ADVISORY marker for the gate relay"
fi

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
