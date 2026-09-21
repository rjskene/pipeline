#!/usr/bin/env bash
#
# Acceptance check for calibration issue 02 (quick-fix).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# Fails against the untouched template (validate_id uses an unanchored
# pattern, so `complete 1x` reaches the store and returns rc 4) and passes
# once the pattern is anchored.
set -uo pipefail

SANDBOX="${1:-$PWD}"
cd "$SANDBOX" || { echo "no such sandbox: $SANDBOX" >&2; exit 9; }

FAILURES=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

CALIB_HOME="$(mktemp -d)"
export CALIB_HOME
trap 'rm -rf "$CALIB_HOME"' EXIT

calib() { bash bin/calibctl "$@"; }

id="$(calib add "a real task" --priority high)"

# --- malformed ids are usage errors -------------------------------------------

for bad_id in '1x' '12abc' 'id=3' '3 '; do
  out="$(calib complete "$bad_id" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'invalid id'; then
    ok "complete '$bad_id' is a validation error (rc 2)"
  else
    bad "complete '$bad_id' should be rc 2 'invalid id', got rc $rc: $out"
  fi
done

out="$(calib complete abc 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "complete 'abc' is still a validation error"
else
  bad "complete 'abc' should be rc 2, got rc $rc: $out"
fi

# --- unknown-but-valid ids are still 'no such task' ---------------------------

out="$(calib complete 99 2>&1)"; rc=$?
if [ "$rc" -eq 4 ] && printf '%s' "$out" | grep -q 'no such task'; then
  ok "complete 99 is still rc 4 'no such task'"
else
  bad "complete 99 should stay rc 4 'no such task', got rc $rc: $out"
fi

# --- the happy path still works -----------------------------------------------

out="$(calib complete "$id" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "completed #$id"; then
  ok "completing a valid id still works"
else
  bad "completing id $id should succeed, got rc $rc: $out"
fi

# --- the regression is covered by the suite -----------------------------------

if grep -qE "1x|12abc" tests/case-*.sh; then
  ok "a test case covers the mixed-input id"
else
  bad "no test case covers a mixed-input id such as 1x"
fi

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 02: PASS"
  exit 0
fi
echo "issue 02: FAIL ($FAILURES check(s))"
exit 1
