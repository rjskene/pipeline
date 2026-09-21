#!/usr/bin/env bash
#
# Acceptance check for calibration issue 05 (edits in two disjoint dirs).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# Fails against the untouched template (the report has no completion rate and
# docs/architecture.md does not mention one) and passes once both lib/report.sh
# and docs/architecture.md are updated.
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

pct() { printf '%s\n' "$1" | sed -n 's/^completion[[:space:]]\+\([0-9]\+\)%$/\1/p'; }

# --- empty ledger ---------------------------------------------------------------

out="$(calib report)"
if [ "$(pct "$out")" = "0" ]; then
  ok "an empty ledger reports completion 0%"
else
  bad "an empty ledger should report 'completion   0%', got: $(printf '%s' "$out" | head -6 | tr '\n' '|')"
fi

# --- partial ledger -------------------------------------------------------------

calib add "cut the release" --priority high >/dev/null
calib add "answer the review" --priority med >/dev/null
calib add "tidy the changelog" --priority low >/dev/null
calib add "delete dead code" --priority high >/dev/null
calib complete 2 >/dev/null

out="$(calib report)"
if [ "$(pct "$out")" = "25" ]; then
  ok "one of four tasks done reports completion 25%"
else
  bad "one of four done should report 'completion  25%', got: $(printf '%s' "$out" | head -6 | tr '\n' '|')"
fi

# --- the new line sits directly under total -------------------------------------

total_line="$(printf '%s\n' "$out" | grep -n '^total' | cut -d: -f1)"
comp_line="$(printf '%s\n' "$out" | grep -n '^completion' | cut -d: -f1)"
if [ -n "$total_line" ] && [ -n "$comp_line" ] && [ "$comp_line" = "$((total_line + 1))" ]; then
  ok "the completion line sits directly under total"
else
  bad "completion should be the line after total (total=$total_line, completion=$comp_line)"
fi

# --- the existing lines are untouched --------------------------------------------

for pattern in '^open +3$' '^done +1$' '^total +4$' '^ +high +2$' '^ +med +1$' '^ +low +1$' '^oldest open: #1 '; do
  if printf '%s\n' "$out" | grep -qE "$pattern"; then
    ok "report still prints /$pattern/"
  else
    bad "report no longer prints /$pattern/"
  fi
done

# --- fully completed ledger -------------------------------------------------------

calib complete 1 >/dev/null
calib complete 3 >/dev/null
calib complete 4 >/dev/null
out="$(calib report)"
if [ "$(pct "$out")" = "100" ]; then
  ok "a fully completed ledger reports completion 100%"
else
  bad "a fully completed ledger should report 100%, got: $(printf '%s' "$out" | head -6 | tr '\n' '|')"
fi

# --- the docs describe it ----------------------------------------------------------

if grep -qi 'completion' docs/architecture.md; then
  ok "docs/architecture.md documents the completion rate"
else
  bad "docs/architecture.md does not mention the completion rate"
fi

if grep -qi 'completion' docs/architecture.md \
   && grep -iA2 -B2 'completion' docs/architecture.md | grep -qiE 'percent|%|done|total'; then
  ok "docs/architecture.md says how the completion rate is derived"
else
  bad "docs/architecture.md should say how the completion rate is derived"
fi

# --- covered by the suite -----------------------------------------------------------

if grep -qi 'completion' tests/case-report.sh 2>/dev/null; then
  ok "tests/case-report.sh asserts on the completion line"
else
  bad "tests/case-report.sh does not assert on the completion line"
fi

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 05: PASS"
  exit 0
fi
echo "issue 05: FAIL ($FAILURES check(s))"
exit 1
