#!/usr/bin/env bash
#
# Acceptance check for calibration issue 06 (planted boundary defect).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# Fails against the untouched template (list truncates nothing) and passes
# once `store_truncate_title` is implemented and wired into `list`'s row
# formatter with the exact boundary this test pins.
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

# print_row's id/status/priority columns are fixed-width ahead of the title:
# `#` + id(4) + ` ` + status(5) + ` ` + priority(5) + ` ` = 18 characters.
# Only the title field's rendering is in scope for this issue, so the
# extraction below assumes that prefix stays untouched.
PREFIX_LEN=18
title_cell() { # <row-line> -> everything after the fixed prefix
  printf '%s' "$1" | cut -c$((PREFIX_LEN + 1))-
}
ends_in_ellipsis() { case "$1" in *...) return 0 ;; *) return 1 ;; esac; }

# --- a short title renders verbatim ---------------------------------------------

SHORT="short title"
calib add "$SHORT" >/dev/null
row="$(calib list 2>&1 | grep '^#1 ')"
cell="$(title_cell "$row")"
if [ "$cell" = "$SHORT" ]; then
  ok "a short title renders verbatim"
else
  bad "a short title should render verbatim, got: '$cell'"
fi

# --- a long title is truncated with a trailing ellipsis -------------------------

LONG50="$(printf 'b%.0s' $(seq 1 50))"
calib add "$LONG50" >/dev/null
row="$(calib list 2>&1 | grep '^#2 ')"
cell="$(title_cell "$row")"
if ends_in_ellipsis "$cell"; then
  ok "a long title ends in an ellipsis"
else
  bad "a long title should end in '...', got: '$cell'"
fi

# --- HIDDEN: the truncated cell is exactly the default width, ellipsis included --

LONG60="$(printf 'c%.0s' $(seq 1 60))"
calib add "$LONG60" >/dev/null
row="$(calib list 2>&1 | grep '^#3 ')"
cell="$(title_cell "$row")"
if [ "${#cell}" -eq 40 ] && ends_in_ellipsis "$cell"; then
  ok "a 60-character title renders a 40-character cell, ellipsis included"
else
  bad "a 60-character title should render EXACTLY 40 characters (got ${#cell}: '$cell')"
fi

# --- HIDDEN: a title of exactly the default width renders verbatim, no ellipsis --

EXACT40="$(printf 'd%.0s' $(seq 1 40))"
calib add "$EXACT40" >/dev/null
row="$(calib list 2>&1 | grep '^#4 ')"
cell="$(title_cell "$row")"
if [ "$cell" = "$EXACT40" ]; then
  ok "a title of exactly 40 characters renders verbatim (equality boundary)"
else
  bad "a 40-character title should render verbatim with no ellipsis, got: '$cell'"
fi

# --- the feature is covered by the suite ----------------------------------------

if grep -lqi 'truncat' tests/case-*.sh 2>/dev/null; then
  ok "a test case file covers title truncation"
else
  bad "no tests/case-*.sh file covers title truncation"
fi

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 06: PASS"
  exit 0
fi
echo "issue 06: FAIL ($FAILURES check(s))"
exit 1
