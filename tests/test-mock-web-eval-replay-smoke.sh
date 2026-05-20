#!/bin/bash
set -uo pipefail

# Smoke test for mock-web-eval/replay/replay.sh (issue #232).
# Asserts the replay helper exists, is executable, parses --dry-run, prints
# expected dry-run markers, and rejects unknown flags. The full end-to-end
# `--full --pr <N>` mode is intentionally NOT exercised here — it requires
# Docker, a live PR, and host credentials, none of which CI provides.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/mock-web-eval/replay/replay.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

echo "=== test-mock-web-eval-replay-smoke ==="

# 1: file exists and is executable
inc
if [ -x "$SCRIPT_UNDER_TEST" ]; then
  pass_msg "replay.sh exists and is executable"
else
  fail_msg "replay.sh missing or not executable at $SCRIPT_UNDER_TEST"
fi

# 2: --dry-run exits 0
inc
DRY_OUT="$(bash "$SCRIPT_UNDER_TEST" --dry-run 2>&1)"
DRY_RC=$?
if [ "$DRY_RC" -eq 0 ]; then
  pass_msg "--dry-run exits 0"
else
  fail_msg "--dry-run exited $DRY_RC; output: $DRY_OUT"
fi

# 3: dry-run output contains probe-port marker
inc
if echo "$DRY_OUT" | grep -q "dry-run: would run probe-port"; then
  pass_msg "dry-run prints probe-port marker"
else
  fail_msg "dry-run missing 'dry-run: would run probe-port'; output: $DRY_OUT"
fi

# 4: dry-run output contains classifier marker
inc
if echo "$DRY_OUT" | grep -q "dry-run: would invoke classifier"; then
  pass_msg "dry-run prints classifier marker"
else
  fail_msg "dry-run missing 'dry-run: would invoke classifier'; output: $DRY_OUT"
fi

# 5: unknown flag exits non-zero
inc
bash "$SCRIPT_UNDER_TEST" --unknown-flag >/dev/null 2>&1
UNK_RC=$?
if [ "$UNK_RC" -ne 0 ]; then
  pass_msg "--unknown-flag exits non-zero"
else
  fail_msg "--unknown-flag unexpectedly exited 0"
fi

echo ""
echo "=== Summary: $PASS/$TESTS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
