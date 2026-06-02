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

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
