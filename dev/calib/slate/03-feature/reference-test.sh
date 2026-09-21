#!/usr/bin/env bash
#
# Acceptance check for calibration issue 03 (plain feature).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# Fails against the untouched template (there is no `search` command) and
# passes once `calibctl search <term>` is implemented and covered by a test
# case file.
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
rows()  { printf '%s\n' "$1" | grep -c '^#'; }

calib add "Write the release notes" --priority high --tag docs >/dev/null
calib add "Fix the flaky lock" --priority med --tag ops >/dev/null
calib add "Prune stale branches" --priority low >/dev/null
calib complete 2 >/dev/null

# --- basic match ---------------------------------------------------------------

out="$(calib search release 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(rows "$out")" = "1" ] \
   && printf '%s' "$out" | grep -q 'release notes'; then
  ok "search finds a task by a word in its title"
else
  bad "search release should print one row, got rc $rc: $out"
fi

if printf '%s' "$out" | grep -qE '^#1 '; then
  ok "search prints the task id in the list row format"
else
  bad "search output should start with '#1' like list does: $out"
fi

# --- case insensitivity --------------------------------------------------------

out="$(calib search LOCK 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'flaky lock'; then
  ok "search is case-insensitive"
else
  bad "search LOCK should match 'Fix the flaky lock', got rc $rc: $out"
fi

# --- completed tasks are included ----------------------------------------------

if printf '%s' "$out" | grep -q 'done'; then
  ok "search includes completed tasks"
else
  bad "search should include the completed task #2: $out"
fi

# --- tags are searched too ------------------------------------------------------

out="$(calib search ops 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'flaky lock'; then
  ok "search matches against tags"
else
  bad "search ops should match the task tagged ops, got rc $rc: $out"
fi

# --- no match / no term ---------------------------------------------------------

out="$(calib search zzzznope 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'no matching tasks'; then
  ok "an unmatched search exits 1 with 'no matching tasks'"
else
  bad "search zzzznope should be rc 1 'no matching tasks', got rc $rc: $out"
fi

out="$(calib search 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "search with no term is a usage error (rc 2)"
else
  bad "search with no term should be rc 2, got rc $rc: $out"
fi

# --- the feature is covered by the suite ----------------------------------------

if grep -lq 'search' tests/case-*.sh 2>/dev/null; then
  ok "a test case file covers search"
else
  bad "no tests/case-*.sh file mentions search"
fi

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 03: PASS"
  exit 0
fi
echo "issue 03: FAIL ($FAILURES check(s))"
exit 1
