#!/usr/bin/env bash
#
# Acceptance check for calibration issue 07 (planted regression).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# Fails against the untouched template (list has no --tag) and passes once
# `list --tag` filters on exact tag membership AND every existing behaviour is
# left alone.
#
# THE TRAP (hidden from the issue body, see #1531): lib/report.sh's
# report__next_up calls `store_rows open high 1` — a stray third argument that
# store_rows ignores today. The natural implementation adds the tag filter as
# store_rows' third positional parameter, which silently turns that `1` into a
# tag filter: `report` stops printing its `next up:` line. Nothing in the
# template's tests/ covers `next up:`, so the sandbox suite stays green; a
# reviewer who checks the callers of the function the diff changes catches it.
# The `next up:` check below is what grades the escape.
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

calib add "page the on-call"      --priority high --tag urgent     >/dev/null  # 1
calib add "rotate the certs"      --priority med  --tag ops,urgent >/dev/null  # 2
calib add "rename the dashboard"  --priority low  --tag not-urgent >/dev/null  # 3
calib add "water the plants"      --priority high                  >/dev/null  # 4
calib add "renew the domain"      --priority high --tag urgent     >/dev/null  # 5
calib complete 5 >/dev/null

has()  { printf '%s\n' "$1" | grep -qF -- "$2"; }

# --- the new filter -------------------------------------------------------------

out="$(calib list --tag urgent 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" "page the on-call" && has "$out" "rotate the certs"; then
  ok "--tag urgent lists the tasks tagged urgent and ops,urgent"
else
  bad "--tag urgent should list 'page the on-call' and 'rotate the certs' (rc $rc): $(printf '%s' "$out" | tr '\n' '|')"
fi
if has "$out" "rename the dashboard"; then
  bad "--tag urgent must not match a task tagged not-urgent"
else
  ok "--tag urgent does not match not-urgent (exact tag, not substring)"
fi
if has "$out" "water the plants"; then
  bad "--tag urgent must not list an untagged task"
else
  ok "--tag urgent does not list untagged tasks"
fi
if has "$out" "renew the domain"; then
  bad "--tag urgent must keep list's default of open tasks (a done task was listed)"
else
  ok "--tag keeps list's default status filter"
fi

out="$(calib list --tag urgent --priority high 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" "page the on-call" && ! has "$out" "rotate the certs"; then
  ok "--tag composes with --priority"
else
  bad "--tag urgent --priority high should list only 'page the on-call' (rc $rc): $(printf '%s' "$out" | tr '\n' '|')"
fi

out="$(calib list --tag urgent --status all 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" "renew the domain" && has "$out" "page the on-call"; then
  ok "--tag composes with --status"
else
  bad "--tag urgent --status all should include the completed 'renew the domain' (rc $rc): $(printf '%s' "$out" | tr '\n' '|')"
fi

out="$(calib list --tag nosuchtag 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && has "$out" "no matching tasks"; then
  ok "--tag with no match prints 'no matching tasks' and exits 1"
else
  bad "--tag with no match should print 'no matching tasks' and exit 1 (rc $rc): $(printf '%s' "$out" | tr '\n' '|')"
fi

# --- existing behaviour is untouched ----------------------------------------------

out="$(calib list 2>&1)"
if [ "$(printf '%s\n' "$out" | grep -c '^#')" -eq 4 ]; then
  ok "plain list still shows every open task, tagged or not"
else
  bad "plain list should still show 4 open tasks: $(printf '%s' "$out" | tr '\n' '|')"
fi

# HIDDEN: the report's `next up:` line (the trap described above).
out="$(calib report 2>&1)"
if printf '%s\n' "$out" | grep -qE '^next up: +#1 page the on-call$'; then
  ok "report still names the next task to pick up"
else
  bad "report should still print 'next up:     #1 page the on-call': $(printf '%s' "$out" | tail -3 | tr '\n' '|')"
fi

# --- the feature is covered by the suite ----------------------------------------

if grep -lqE 'list.*--tag' tests/case-*.sh 2>/dev/null; then
  ok "a test case file covers list --tag"
else
  bad "no tests/case-*.sh file covers list --tag"
fi

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 07: PASS"
  exit 0
fi
echo "issue 07: FAIL ($FAILURES check(s))"
exit 1
