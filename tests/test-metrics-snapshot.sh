#!/bin/bash
set -uo pipefail
#
# Tests for scripts/metrics-snapshot.sh — dogfood-only daily snapshot
# (issue #576). Aggregates over-eval-report, late-error-report,
# compliance-backfill, review-audits into one JSONL row appended to
# .claude/logs/metrics-timeseries.jsonl.
#
# Uses fixture mode (--fixture <dir>) so no live `gh` calls are required.
# The fixture directory must contain four subdirs:
#   over-eval/      — passed through to over-eval-report.sh --fixture
#   late-error/     — passed through to late-error-report.sh --fixture
#   compliance/     — passed through to compliance-backfill.sh --fixture
#   review-audits/  — contains output.txt (one deviation row per line);
#                     read directly because review-audits.sh has no
#                     --fixture flag (intentionally — keeps the snapshot
#                     fixture story hermetic without expanding the
#                     review-audits CLI surface).
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/metrics-snapshot.sh"
FIXTURE_ROOT="$REPO_ROOT/tests/fixtures/metrics-snapshot"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

inc_scenario() { echo ""; echo "-- $1 --"; }

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

# --- Scenario 1: scaffolding ---
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/metrics-snapshot.sh"
else
  fail_msg "script file missing at scripts/metrics-snapshot.sh"
fi

if [ -x "$HELPER" ]; then
  pass_msg "script is executable"
else
  fail_msg "script is not executable"
fi

HELP_OUT=$(bash "$HELPER" --help 2>&1)
HELP_RC=$?
if [ "$HELP_RC" -eq 0 ] && echo "$HELP_OUT" | grep -q "metrics-snapshot.sh"; then
  pass_msg "--help exits 0 and prints banner"
else
  fail_msg "--help rc=$HELP_RC banner missing"
fi

if echo "$HELP_OUT" | grep -qi "DOGFOOD"; then
  pass_msg "--help banner mentions DOGFOOD"
else
  fail_msg "--help banner missing DOGFOOD callout"
fi

# --- Scenario 2: first append produces a valid JSONL row ---
inc_scenario "Scenario 2: first append produces one valid JSONL row"

OUT_FILE="$TMPDIR_T/metrics.jsonl"

if [ ! -d "$FIXTURE_ROOT" ]; then
  fail_msg "fixture root missing: $FIXTURE_ROOT"
fi

bash "$HELPER" --fixture "$FIXTURE_ROOT" --out "$OUT_FILE" >/dev/null 2>&1
RC1=$?
if [ "$RC1" -eq 0 ]; then
  pass_msg "snapshot run exits 0"
else
  fail_msg "snapshot run exit=$RC1 (expected 0)"
fi

if [ -f "$OUT_FILE" ]; then
  LINES1=$(wc -l < "$OUT_FILE" | tr -d ' ')
  if [ "$LINES1" -eq 1 ]; then
    pass_msg "first run appended exactly 1 line"
  else
    fail_msg "first run produced $LINES1 lines (expected 1)"
  fi
else
  fail_msg "out file not created"
fi

if [ -f "$OUT_FILE" ] && jq -e . "$OUT_FILE" >/dev/null 2>&1; then
  pass_msg "row is valid JSON"
else
  fail_msg "row is not valid JSON"
fi

# Required keys + types
if [ -f "$OUT_FILE" ] && jq -e '
  .date and .pipeline_version
  and (.over_eval_count | type == "number")
  and (.late_error_count_by_stage | type == "object")
  and ((.compliance_pass_rate | type == "number") or (.compliance_pass_rate == null))
  and (.review_deviations_count | type == "number")
' "$OUT_FILE" >/dev/null 2>&1; then
  pass_msg "row has required keys with expected types"
else
  fail_msg "row missing required keys or wrong types"
fi

# ISO YYYY-MM-DD date
if [ -f "$OUT_FILE" ] && jq -re '.date' "$OUT_FILE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  pass_msg "date is ISO YYYY-MM-DD"
else
  fail_msg "date is not ISO YYYY-MM-DD"
fi

# Stable canonical stage keys
if [ -f "$OUT_FILE" ] && jq -e '
  .late_error_count_by_stage
  | has("issue") and has("plan") and has("plan-eval") and has("pr-eval")
' "$OUT_FILE" >/dev/null 2>&1; then
  pass_msg "late_error_count_by_stage has all 4 canonical keys"
else
  fail_msg "late_error_count_by_stage missing canonical keys"
fi

# --- Scenario 3: idempotent append (1 → 2 lines, first row preserved) ---
inc_scenario "Scenario 3: idempotent append (never truncate)"

FIRST_ROW_BYTES=$(head -1 "$OUT_FILE" 2>/dev/null | md5sum | awk '{print $1}')

bash "$HELPER" --fixture "$FIXTURE_ROOT" --out "$OUT_FILE" >/dev/null 2>&1
RC2=$?
if [ "$RC2" -eq 0 ]; then
  pass_msg "second snapshot run exits 0"
else
  fail_msg "second snapshot run exit=$RC2"
fi

LINES2=$(wc -l < "$OUT_FILE" 2>/dev/null | tr -d ' ')
if [ "$LINES2" -eq 2 ]; then
  pass_msg "second run appended (wc -l: 1 → 2)"
else
  fail_msg "expected 2 lines, got $LINES2"
fi

PRESERVED_BYTES=$(head -1 "$OUT_FILE" 2>/dev/null | md5sum | awk '{print $1}')
if [ "$FIRST_ROW_BYTES" = "$PRESERVED_BYTES" ]; then
  pass_msg "first row preserved byte-for-byte after second append"
else
  fail_msg "first row mutated by second append"
fi

# --- Scenario 4: sibling failure → null field, snapshot still exit 0 ---
inc_scenario "Scenario 4: sibling failure degrades to null"

BROKEN_FIXTURE="$TMPDIR_T/broken-fixture"
mkdir -p "$BROKEN_FIXTURE/over-eval"  # intentionally empty: no prs.json → over-eval fails
cp -r "$FIXTURE_ROOT/late-error" "$BROKEN_FIXTURE/"
cp -r "$FIXTURE_ROOT/compliance" "$BROKEN_FIXTURE/"
cp -r "$FIXTURE_ROOT/review-audits" "$BROKEN_FIXTURE/"

OUT_BROKEN="$TMPDIR_T/metrics-broken.jsonl"
bash "$HELPER" --fixture "$BROKEN_FIXTURE" --out "$OUT_BROKEN" >/dev/null 2>&1
RC_BROKEN=$?
if [ "$RC_BROKEN" -eq 0 ]; then
  pass_msg "snapshot exits 0 even when one sibling fails"
else
  fail_msg "snapshot exit=$RC_BROKEN (expected 0; partial-day signal beats no-day signal)"
fi

if [ -f "$OUT_BROKEN" ] && jq -e '.over_eval_count == null' "$OUT_BROKEN" >/dev/null 2>&1; then
  pass_msg "failed sibling field is null"
else
  fail_msg "expected over_eval_count == null on sibling failure"
fi

# Other fields should still be populated
if [ -f "$OUT_BROKEN" ] && jq -e '.late_error_count_by_stage | type == "object"' "$OUT_BROKEN" >/dev/null 2>&1; then
  pass_msg "other-sibling fields still populated when one fails"
else
  fail_msg "non-failing siblings should still produce values"
fi

# --- Scenario 5: --dry-run emits row to stdout, does not append ---
inc_scenario "Scenario 5: --dry-run prints row, does not append"

OUT_DRY="$TMPDIR_T/metrics-dry.jsonl"
touch "$OUT_DRY"
DRY_OUT=$(bash "$HELPER" --fixture "$FIXTURE_ROOT" --out "$OUT_DRY" --dry-run 2>/dev/null)
DRY_RC=$?
DRY_LINES=$(wc -l < "$OUT_DRY" 2>/dev/null | tr -d ' ')

if [ "$DRY_RC" -eq 0 ]; then
  pass_msg "--dry-run exits 0"
else
  fail_msg "--dry-run exit=$DRY_RC"
fi

if [ "$DRY_LINES" -eq 0 ]; then
  pass_msg "--dry-run does not touch --out file"
else
  fail_msg "--dry-run wrote $DRY_LINES lines to --out (should be 0)"
fi

if echo "$DRY_OUT" | jq -e . >/dev/null 2>&1; then
  pass_msg "--dry-run stdout is valid JSON"
else
  fail_msg "--dry-run stdout is not valid JSON"
fi

# --- Summary ---
echo ""
echo "=================================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "=================================="
exit "$FAIL"
