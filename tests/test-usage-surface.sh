#!/bin/bash
set -uo pipefail
#
# Tests for scripts/usage-surface.sh — dogfood-only rolling-window usage
# read-out (issue #725). Reads ONLY the gated #642/#721 capture JSONL
# (.claude/logs/agent-costs.jsonl) and reports window-token-usage, headroom,
# and a throttle-ETA projection. READ-ONLY: no writes, no control loop.
#
# Fixture-driven, deterministic via an injected --now clock; no live `gh`.
# Fixtures live in tests/fixtures/usage-surface/:
#   - capture-window.jsonl — records inside + outside the rolling window
#   - capture-empty.jsonl   — empty capture (graceful-degrade)
#   - capture-dup.jsonl     — recurring record_key + duplicate (session,issue,stage)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/usage-surface.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/usage-surface"
CONFIG_EXAMPLE="$REPO_ROOT/pipeline.config.example"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

# --- Scenario 1: scaffolding (existence + executable + --help banner) ---
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/usage-surface.sh"
else
  fail_msg "script file missing at scripts/usage-surface.sh"
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
if printf '%s' "$HELP_OUT" | grep -q 'usage-surface'; then
  pass_msg "--help prints usage-surface"
else
  fail_msg "--help missing usage-surface banner"
fi

# --- Scenario 2: gating + graceful-degrade ---
inc_scenario "Scenario 2: gating + graceful-degrade"

# 2a: logs disabled → single SKIP_LOGGING_DISABLED line, exit 0.
G2A="$(PIPELINE_LOGS_ENABLED=false bash "$HELPER" --cap-tokens 1000000 2>&1)"; G2A_RC=$?
if [ "$G2A_RC" -eq 0 ]; then pass_msg "logs disabled exits 0"; else fail_msg "logs disabled exited non-zero (rc=$G2A_RC)"; fi
if printf '%s' "$G2A" | grep -q 'SKIP_LOGGING_DISABLED'; then pass_msg "logs disabled prints SKIP_LOGGING_DISABLED"; else fail_msg "logs disabled missing SKIP_LOGGING_DISABLED (got: $G2A)"; fi

# 2b: logs enabled but cap unset → disabled-(unset) line, exit 0.
G2B="$(PIPELINE_LOGS_ENABLED=true PIPELINE_USAGE_CAP_TOKENS= bash "$HELPER" 2>&1)"; G2B_RC=$?
if [ "$G2B_RC" -eq 0 ]; then pass_msg "cap unset exits 0"; else fail_msg "cap unset exited non-zero (rc=$G2B_RC)"; fi
if printf '%s' "$G2B" | grep -q 'disabled (PIPELINE_USAGE_CAP_TOKENS unset)'; then pass_msg "cap unset prints disabled line"; else fail_msg "cap unset missing disabled line (got: $G2B)"; fi

# 2c: cap set but capture log absent → read-out with -- placeholders, exit 0.
G2C="$(PIPELINE_LOGS_ENABLED=true bash "$HELPER" --cap-tokens 1000000 --capture-log "$FIXTURE_DIR/does-not-exist.jsonl" 2>&1)"; G2C_RC=$?
if [ "$G2C_RC" -eq 0 ]; then pass_msg "absent log exits 0"; else fail_msg "absent log exited non-zero (rc=$G2C_RC)"; fi
if printf '%s' "$G2C" | grep -q 'window=--'; then pass_msg "absent log renders window=-- placeholder"; else fail_msg "absent log missing window=-- (got: $G2C)"; fi

# 2d: cap set but capture log empty → read-out with -- placeholders, exit 0.
G2D="$(PIPELINE_LOGS_ENABLED=true bash "$HELPER" --cap-tokens 1000000 --capture-log "$FIXTURE_DIR/capture-empty.jsonl" 2>&1)"; G2D_RC=$?
if [ "$G2D_RC" -eq 0 ]; then pass_msg "empty log exits 0"; else fail_msg "empty log exited non-zero (rc=$G2D_RC)"; fi
if printf '%s' "$G2D" | grep -q 'window=--'; then pass_msg "empty log renders window=-- placeholder"; else fail_msg "empty log missing window=-- (got: $G2D)"; fi

# --- Scenario 3: window-usage math + dedup contract ---
inc_scenario "Scenario 3: window-usage math + dedup contract"

# 3a: in-window deduped sum, out-of-window record excluded.
# Inside the 5h window (cutoff 2026-06-02T07:00:00Z): 10000+20000+30000 = 60000.
# The 2026-06-02T05:00:00Z record (total 99999) must be excluded.
W3="$(PIPELINE_LOGS_ENABLED=true bash "$HELPER" \
  --capture-log "$FIXTURE_DIR/capture-window.jsonl" \
  --window-hours 5 --cap-tokens 1000000 --now 2026-06-02T12:00:00Z 2>&1)"
if printf '%s' "$W3" | grep -q 'window=60000tok'; then pass_msg "window sum excludes out-of-window record (=60000tok)"; else fail_msg "wrong window sum (got: $W3)"; fi

# 3b: dedup — recurring record_key counted ONCE (last-write-wins) and a same
# (session,issue,stage) pair collapses to max_by(total).
# DK1 last-write 12000 + DK2 max(7000,18000)=18000 → 30000.
WD="$(PIPELINE_LOGS_ENABLED=true bash "$HELPER" \
  --capture-log "$FIXTURE_DIR/capture-dup.jsonl" \
  --window-hours 5 --cap-tokens 1000000 --now 2026-06-02T12:00:00Z 2>&1)"
if printf '%s' "$WD" | grep -q 'window=30000tok'; then pass_msg "dedup: record_key last-write + (session,issue,stage) max_by (=30000tok)"; else fail_msg "wrong deduped sum (got: $WD)"; fi

# --- Scenario 4: headroom + throttle-ETA ---
inc_scenario "Scenario 4: headroom + throttle-ETA"

# 4a: headroom = cap - window_sum (floored at 0). cap 120000, window 60000 → 60000.
# burn = 60000 / span(=min(5, 12:00-08:00=4)=4h) = 15000/h.
# eta_minutes = 60000 / 15000 * 60 = 240m → "~4h 0m".
H4="$(PIPELINE_LOGS_ENABLED=true bash "$HELPER" \
  --capture-log "$FIXTURE_DIR/capture-window.jsonl" \
  --window-hours 5 --cap-tokens 120000 --now 2026-06-02T12:00:00Z 2>&1)"
if printf '%s' "$H4" | grep -q 'headroom=60000tok'; then pass_msg "headroom = cap - window_sum (=60000tok)"; else fail_msg "wrong headroom (got: $H4)"; fi
if printf '%s' "$H4" | grep -q 'throttle-ETA ~4h 0m'; then pass_msg "throttle-ETA ~4h 0m at observed burn"; else fail_msg "wrong throttle-ETA (got: $H4)"; fi

# 4b: usage >= cap → headroom 0tok, ETA "now (cap reached)".
H4B="$(PIPELINE_LOGS_ENABLED=true bash "$HELPER" \
  --capture-log "$FIXTURE_DIR/capture-window.jsonl" \
  --window-hours 5 --cap-tokens 50000 --now 2026-06-02T12:00:00Z 2>&1)"
if printf '%s' "$H4B" | grep -q 'headroom=0tok'; then pass_msg "cap reached → headroom=0tok"; else fail_msg "cap reached headroom not 0 (got: $H4B)"; fi
if printf '%s' "$H4B" | grep -q 'throttle-ETA now (cap reached)'; then pass_msg "cap reached → ETA now (cap reached)"; else fail_msg "cap reached ETA wrong (got: $H4B)"; fi

# 4c: zero burn (no in-window records) → ETA "--", headroom = cap (no div0).
# now far in the future so all fixture records fall outside the window.
H4C="$(PIPELINE_LOGS_ENABLED=true bash "$HELPER" \
  --capture-log "$FIXTURE_DIR/capture-window.jsonl" \
  --window-hours 5 --cap-tokens 120000 --now 2026-06-09T12:00:00Z 2>&1)"
if printf '%s' "$H4C" | grep -q 'window=0tok'; then pass_msg "no in-window records → window=0tok"; else fail_msg "expected window=0tok (got: $H4C)"; fi
if printf '%s' "$H4C" | grep -q 'headroom=120000tok'; then pass_msg "zero burn → headroom = cap"; else fail_msg "zero burn headroom wrong (got: $H4C)"; fi
if printf '%s' "$H4C" | grep -q 'throttle-ETA --'; then pass_msg "zero burn → ETA -- (no div0)"; else fail_msg "zero burn ETA not -- (got: $H4C)"; fi

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
