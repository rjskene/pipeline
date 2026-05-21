#!/bin/bash
set -uo pipefail

# Tests for scripts/render-status-table.sh — the deterministic, hermetic
# renderer that consumes (issues.json, trackers.json, release-prs.txt) and
# writes the canonical pipeline status table to stdout.
#
# The renderer makes ZERO live `gh` calls. All inputs are passed as files,
# which is what makes this testable in shell.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/render-status-table.sh"
FIXTURES="$SCRIPT_DIR/fixtures/render-status-table"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); echo "    $2"; }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# ----------------------------------------------------------------------
# Task 1: skeleton + arg parsing
# ----------------------------------------------------------------------

# Scenario 1.1: no arguments → exit 2 + usage to stderr
inc
out=$(bash "$HELPER" 2>"$TMP/err" || true)
rc=$?
err=$(cat "$TMP/err")
if bash "$HELPER" >/dev/null 2>"$TMP/err"; rc=$?; [ "$rc" -eq 2 ] && grep -q -i 'usage' "$TMP/err"; then
  pass_msg "no args → exit 2 + usage on stderr"
else
  fail_msg "no args → exit 2 + usage on stderr" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# Scenario 1.2: --issues pointing at a nonexistent file → exit 2 + error
inc
bash "$HELPER" --issues "$TMP/does-not-exist.json" >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "does-not-exist.json" "$TMP/err"; then
  pass_msg "missing --issues file → exit 2 + error mentions file"
else
  fail_msg "missing --issues file → exit 2 + error mentions file" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# Scenario 1.3: --issues with a valid empty file (just '[]') exits 0
inc
echo '[]' > "$TMP/empty-issues.json"
bash "$HELPER" --issues "$TMP/empty-issues.json" --today 2026-05-21 >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "empty issues array → exit 0"
else
  fail_msg "empty issues array → exit 0" "rc=$rc, stderr=$(cat "$TMP/err"), stdout=$(cat "$TMP/out")"
fi

# ----------------------------------------------------------------------
# Task 2: ORPHANS section — scope buckets + priority sort + stage
# ----------------------------------------------------------------------

# Scenario 2.1: 4 orphans across 3 scope buckets render in alphabetical
# bucket order with (none / generic) last; rows within a bucket sort by
# priority tier; each row uses `[Pn] #N — <title>  (stage)`.
inc
bash "$HELPER" \
  --issues "$FIXTURES/orphans-issues.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
out=$(cat "$TMP/out")
if [ "$rc" -ne 0 ]; then
  fail_msg "orphans render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  # ORPHANS header exists
  if grep -q '^ORPHANS' "$TMP/out"; then
    pass_msg "orphans render emits ORPHANS header"
  else
    fail_msg "orphans render emits ORPHANS header" "$out"
  fi

  inc
  # bucket order: (doctor) before (run) before (none / generic)
  doctor_line=$(grep -n '^ (doctor)' "$TMP/out" | head -1 | cut -d: -f1)
  run_line=$(grep -n '^ (run)' "$TMP/out" | head -1 | cut -d: -f1)
  none_line=$(grep -n '^ (none / generic)' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$doctor_line" ] && [ -n "$run_line" ] && [ -n "$none_line" ] \
     && [ "$doctor_line" -lt "$run_line" ] && [ "$run_line" -lt "$none_line" ]; then
    pass_msg "bucket order: (doctor) < (run) < (none / generic)"
  else
    fail_msg "bucket order: (doctor) < (run) < (none / generic)" \
      "doctor=$doctor_line run=$run_line none=$none_line"
  fi

  inc
  # within (run): P1 issue #133 appears before P2 issue #34
  p133_line=$(grep -n '#133' "$TMP/out" | head -1 | cut -d: -f1)
  p34_line=$(grep -n '#34 ' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$p133_line" ] && [ -n "$p34_line" ] && [ "$p133_line" -lt "$p34_line" ]; then
    pass_msg "within (run): P1 #133 before P2 #34"
  else
    fail_msg "within (run): P1 #133 before P2 #34" "p133=$p133_line p34=$p34_line"
  fi

  inc
  # row format: `[P1] #133 — feat(run): ... (plan-pending)` with stage
  if grep -qE '^[[:space:]]+\[P1\][[:space:]]+#133[[:space:]]+—.*\(plan-pending\)' "$TMP/out"; then
    pass_msg "row format includes [Pn], em-dash, and (stage)"
  else
    fail_msg "row format includes [Pn], em-dash, and (stage)" "$(grep '#133' "$TMP/out")"
  fi

  inc
  # #150 stage resolves to (merged) from the merged label
  if grep -qE '#150.*\(merged\)' "$TMP/out"; then
    pass_msg "stage label resolves merged label for #150"
  else
    fail_msg "stage label resolves merged label for #150" "$(grep '#150' "$TMP/out")"
  fi

  inc
  # #34 has no pipeline-stage label, so renders as (ready)
  if grep -qE '#34[[:space:]].*\(ready\)' "$TMP/out"; then
    pass_msg "no-stage-label issue #34 renders as (ready)"
  else
    fail_msg "no-stage-label issue #34 renders as (ready)" "$(grep '#34 ' "$TMP/out")"
  fi

  inc
  # #999 (chore: bump tooling — no scope parens) lands in (none / generic)
  none_anchor=$(grep -n '^ (none / generic)' "$TMP/out" | head -1 | cut -d: -f1)
  p999_anchor=$(grep -n '#999' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$none_anchor" ] && [ -n "$p999_anchor" ] && [ "$p999_anchor" -gt "$none_anchor" ]; then
    pass_msg "#999 (no-scope title) lands under (none / generic)"
  else
    fail_msg "#999 (no-scope title) lands under (none / generic)" \
      "none=$none_anchor p999=$p999_anchor"
  fi
fi

# ----------------------------------------------------------------------
# Task 3: EPICS section + tracker child rollup + ORPHANS dedup
# ----------------------------------------------------------------------

inc
bash "$HELPER" \
  --issues "$FIXTURES/epics-issues.json" \
  --trackers "$FIXTURES/epics-trackers.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "epics render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  pass_msg "epics render exits 0"

  inc
  epics_line=$(grep -n '^EPICS' "$TMP/out" | head -1 | cut -d: -f1)
  orphans_line=$(grep -n '^ORPHANS' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$epics_line" ] && [ -n "$orphans_line" ] && [ "$epics_line" -lt "$orphans_line" ]; then
    pass_msg "EPICS section renders above ORPHANS"
  else
    fail_msg "EPICS section renders above ORPHANS" "epics=$epics_line orphans=$orphans_line"
  fi

  inc
  # tracker row uses [Pn] #N — title format (no stage in parens)
  if grep -qE '^[[:space:]]+\[P1\][[:space:]]+#120[[:space:]]+—' "$TMP/out"; then
    pass_msg "tracker #120 row uses [Pn] #N — title"
  else
    fail_msg "tracker #120 row uses [Pn] #N — title" "$(grep '#120' "$TMP/out")"
  fi

  inc
  # children indented 8 spaces, with right-padded stage in parens
  if grep -qE '^        #144[[:space:]]+—.*\(plan-approved\)' "$TMP/out"; then
    pass_msg "child #144 indented 8 spaces with stage"
  else
    fail_msg "child #144 indented 8 spaces with stage" "$(grep '#144' "$TMP/out")"
  fi

  inc
  # children appear in their tracker's section, BELOW the tracker line
  t120_line=$(grep -n '#120' "$TMP/out" | head -1 | cut -d: -f1)
  c144_line=$(grep -n '#144' "$TMP/out" | head -1 | cut -d: -f1)
  c146_line=$(grep -n '#146' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$t120_line" ] && [ -n "$c144_line" ] && [ "$t120_line" -lt "$c144_line" ] && [ "$c144_line" -lt "$c146_line" ]; then
    pass_msg "tracker #120 followed by children #144, #146"
  else
    fail_msg "tracker #120 followed by children #144, #146" "t120=$t120_line c144=$c144_line c146=$c146_line"
  fi

  inc
  # tracker with no open children collapses to placeholder
  if grep -qE 'all children closed' "$TMP/out"; then
    pass_msg "tracker with no open children renders placeholder"
  else
    fail_msg "tracker with no open children renders placeholder" "$(grep -A1 '#131' "$TMP/out")"
  fi

  inc
  # children NOT included in ORPHANS — count of #144 lines must equal 1
  c144_count=$(grep -c '#144' "$TMP/out")
  if [ "$c144_count" -eq 1 ]; then
    pass_msg "child #144 deduplicated (only appears once, in EPICS)"
  else
    fail_msg "child #144 deduplicated (only appears once, in EPICS)" "count=$c144_count"
  fi

  inc
  # orphan #999 still in (none / generic) bucket
  if grep -qE '#999[[:space:]]+—.*\(ready\)' "$TMP/out"; then
    pass_msg "orphan #999 still appears in ORPHANS bucket"
  else
    fail_msg "orphan #999 still appears in ORPHANS bucket" "$(grep '#999' "$TMP/out")"
  fi
fi

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "TOTAL: $TESTS  PASS: $PASS  FAIL: $FAIL"
echo "=========================================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
