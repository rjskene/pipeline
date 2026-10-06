#!/usr/bin/env bash
#
# Acceptance check for calibration issue 01 (docs-only).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# Fails against the untouched template (docs/usage.md still advertises a
# `--all` flag that bin/calibctl does not implement) and passes once the
# "Listing tasks" section documents `--status open|done|all` instead.
set -uo pipefail

SANDBOX="${1:-$PWD}"
cd "$SANDBOX" || { echo "no such sandbox: $SANDBOX" >&2; exit 9; }

FAILURES=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

# --- the behaviour the docs are supposed to describe --------------------------

out="$(bash bin/calibctl list --all 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'unknown option'; then
  ok "bin/calibctl still rejects --all (the CLI was not changed)"
else
  bad "bin/calibctl list --all should stay a usage error (rc 2), got rc $rc: $out"
fi

home="$(mktemp -d)"
CALIB_HOME="$home" bash bin/calibctl add "a task" >/dev/null 2>&1
out="$(CALIB_HOME="$home" bash bin/calibctl list --status all 2>&1)"; rc=$?
rm -rf "$home"
if [ "$rc" -eq 0 ]; then
  ok "--status all is the supported way to see every task"
else
  bad "--status all should succeed, got rc $rc: $out"
fi

# --- the documentation ---------------------------------------------------------

if grep -q -- '--all' docs/usage.md; then
  bad "docs/usage.md still documents the non-existent --all flag"
else
  ok "docs/usage.md no longer documents --all"
fi

# Semantic, not literal: the docs are right whenever one sentence / paragraph /
# code block names --status together with all three values, however it is
# phrased. Calibration run #17 wrote "`--status` accepts `open|done|all`" — a
# correct fix the old literal grep for '--status open|done|all' scored FAIL.
# awk RS="" walks blank-line-delimited blocks, so a hard-wrapped sentence still
# counts; the value patterns reject `--all`, `total` and `reopen`.
if awk 'BEGIN { RS = "" }
  $0 ~ /--status/ \
  && $0 ~ /(^|[^a-zA-Z0-9_-])open([^a-zA-Z0-9_-]|$)/ \
  && $0 ~ /(^|[^a-zA-Z0-9_-])done([^a-zA-Z0-9_-]|$)/ \
  && $0 ~ /(^|[^a-zA-Z0-9_-])all([^a-zA-Z0-9_-]|$)/ { found = 1 }
  END { if (found) exit 0; exit 1 }' docs/usage.md; then
  ok "docs/usage.md documents --status open|done|all"
else
  bad "docs/usage.md should document '--status open|done|all'"
fi

if grep -iE -- '--status[[:space:]]+open' docs/usage.md | grep -qi 'default' \
   || grep -i 'default' docs/usage.md | grep -q -- '--status open'; then
  ok "docs/usage.md states that --status open is the default"
else
  bad "docs/usage.md should say the default is --status open"
fi

# --- nothing else regressed ----------------------------------------------------

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is still green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 01: PASS"
  exit 0
fi
echo "issue 01: FAIL ($FAILURES check(s))"
exit 1
