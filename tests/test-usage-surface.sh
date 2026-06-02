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

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
