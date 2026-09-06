#!/usr/bin/env bash
#
# Acceptance check for calibration issue 04 (race in the auth token helper).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# Fails against the untouched template (auth_issue_token truncates the token
# file before appending, so a reader mid-rotation sees an empty file) and
# passes once publication is atomic.
#
# The CALIB_AUTH_SLOW seam makes the window deterministic — no scheduler luck
# required.
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
TOKEN_FILE="$CALIB_HOME/auth.token"
HEX='^[0-9a-f]{32}$'

first="$(calib auth issue)"
if printf '%s' "$first" | grep -qE "$HEX"; then
  ok "a token can be issued"
else
  bad "auth issue should print 32 hex characters, got '$first'"
fi

# --- a reader mid-rotation sees a complete token -------------------------------

( CALIB_AUTH_SLOW=1 bash bin/calibctl auth issue >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.4

if [ -s "$TOKEN_FILE" ]; then
  ok "the token file is never empty during a rotation"
else
  bad "the token file was empty (or missing) mid-rotation"
fi

mid="$(calib auth show 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$mid" | grep -qE "$HEX"; then
  ok "auth show returns a complete token during a rotation"
else
  bad "auth show mid-rotation should return a token, got rc $rc: $mid"
fi

lines="$(wc -l < "$TOKEN_FILE" | tr -d ' ')"
if [ "$lines" = "1" ]; then
  ok "the token file holds exactly one line during a rotation"
else
  bad "the token file holds $lines lines during a rotation (want 1)"
fi

sleep 1.2
after="$(calib auth show 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$after" | grep -qE "$HEX" && [ "$after" != "$first" ]; then
  ok "the rotation completed and published a new token"
else
  bad "after the rotation auth show should return a new token, got rc $rc: $after"
fi

# --- concurrent rotations leave a single well-formed token ----------------------

for _ in 1 2 3 4 5 6 7 8; do
  ( bash bin/calibctl auth issue >/dev/null 2>&1 & ) >/dev/null 2>&1
done
sleep 1

final="$(calib auth show 2>&1)"; rc=$?
lines="$(wc -l < "$TOKEN_FILE" | tr -d ' ')"
if [ "$rc" -eq 0 ] && printf '%s' "$final" | grep -qE "$HEX" && [ "$lines" = "1" ]; then
  ok "concurrent rotations leave exactly one well-formed token"
else
  bad "after concurrent rotations: rc $rc, $lines line(s), token '$final'"
fi

# --- the regression is covered and nothing else broke ---------------------------

if grep -q 'CALIB_AUTH_SLOW' tests/case-auth.sh 2>/dev/null; then
  ok "tests/case-auth.sh covers the rotation window"
else
  bad "tests/case-auth.sh does not exercise the rotation window (CALIB_AUTH_SLOW)"
fi

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 04: PASS"
  exit 0
fi
echo "issue 04: FAIL ($FAILURES check(s))"
exit 1
