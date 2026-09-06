#!/bin/bash
set -euo pipefail
# Guard: docs/calibration.md is the operator guide for the calibration slate
# (spec 2026-09-05-harness-evolve-loop-design.md section 8). It must document
# every calibration-run.sh mode, the three PIPELINE_CALIB_* knobs, the cost
# band + headless-billing note, the two spec triggers, the CALIB summary-line
# grammar, and the harness-rooted tee target. docs/retros/README.md must point
# at the calib substrate directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO_ROOT/docs/calibration.md"
RETRO_README="$REPO_ROOT/docs/retros/README.md"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  TESTS=$((TESTS + 1))
  if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

assert_matches() {
  local file="$1" pattern="$2" label="$3"
  TESTS=$((TESTS + 1))
  if [ -f "$file" ] && grep -qiE -- "$pattern" "$file"; then
    pass_msg "$label"
  else
    fail_msg "$label (no match: $pattern)"
  fi
}

echo "docs/calibration.md — presence"
TESTS=$((TESTS + 1))
if [ -f "$DOC" ]; then pass_msg "docs/calibration.md exists"; else fail_msg "docs/calibration.md not present"; fi

echo ""
echo "docs/calibration.md — modes"
for mode in -- --bootstrap --reset --dry-run --run; do
  [ "$mode" = "--" ] && continue
  assert_contains "$DOC" "$mode" "documents $mode"
done

echo ""
echo "docs/calibration.md — knobs"
for knob in PIPELINE_CALIB_DIR PIPELINE_CALIB_TIMEOUT PIPELINE_CALIB_REPO; do
  assert_contains "$DOC" "$knob" "documents $knob"
done

echo ""
echo "docs/calibration.md — cost + billing"
assert_contains "$DOC" '≈$60–120' "states the per-run cost band"
assert_contains "$DOC" 'claude -p' "names the headless claude -p launch"
assert_matches "$DOC" 'bill(s|ed|ing)[^.]*headless|headless[^.]*bill(s|ed|ing)' \
  "notes the run bills the account headlessly"

echo ""
echo "docs/calibration.md — spec section 8 triggers"
assert_contains "$DOC" 'Measured by:' "trigger 1: Measured by: marker"
assert_contains "$DOC" 'calibration run' "trigger 1: calibration run value"
assert_matches "$DOC" 'once per seven cycles' "trigger 2: seven-cycle cadence"
assert_matches "$DOC" 'once per seven cycles[^.]*strict|strict[^.]*sonnet' \
  "trigger 2: strict + sonnet weak-model guarantee"

echo ""
echo "docs/calibration.md — CALIB line grammar"
assert_contains "$DOC" \
  'CALIB issue=<n> path=<X> cost=<$> wall=<s> verdicts=<plan-eval/pr-eval> reftest=<pass|fail> unexpected-files=<n>' \
  "per-issue CALIB line grammar"
assert_contains "$DOC" \
  'CALIB-TOTAL cost=<$> wall=<s> issues=<n> reftest-pass=<n>/<n>' \
  "CALIB-TOTAL line grammar"

echo ""
echo "docs/calibration.md — artifact + retro ingest"
assert_contains "$DOC" '$HARNESS/docs/retros/calib/<date>.txt' "harness-rooted tee target"
assert_contains "$DOC" 'run-retro.sh' "names the retro ingest script"
assert_contains "$DOC" 'weak-model pass' "ingest: weak-model pass row"
assert_contains "$DOC" 'median path b pr/usd' "ingest: median path b pr/usd computed value"

echo ""
echo "docs/calibration.md — no anchored cross-references"
TESTS=$((TESTS + 1))
if [ -f "$DOC" ] && grep -qE '\.md#[A-Za-z0-9_-]+' "$DOC"; then
  fail_msg "doc contains anchored .md# cross-references"
else
  pass_msg "doc contains no anchored .md# cross-references"
fi

echo ""
echo "docs/retros/README.md — calib substrate pointer"
assert_contains "$RETRO_README" 'docs/retros/calib/' "retros README mentions docs/retros/calib/"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
