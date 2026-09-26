#!/bin/bash
set -euo pipefail
# Guard: docs/calibration.md is the operator guide for the calibration slate
# (spec 2026-09-05-harness-evolve-loop-design.md section 8). It must document
# every calibration-run.sh mode, the three calibration knobs, the cost
# band + headless-billing note, the two spec triggers, the CALIB summary-line
# grammar, and the harness-rooted tee target. docs/retros/README.md must point
# at the calib substrate directory.
#
# Both files must describe run-retro.sh's ingest AS IMPLEMENTED (#1280 review):
# the weak-model ratio is counted from the per-issue `reftest=` atoms (the
# CALIB-TOTAL line is not parsed), the CALIB grammar carries no profile/model/
# date atom while the row itself still dates the run from the artifact FILENAME
# and flags a stale one (#1395), the path-B median reads `path=B` rows only,
# and the per-issue `cost=` is a token-share apportionment of the run's priced
# total (an estimate, not a measured per-issue charge).
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

assert_not_matches() {
  local file="$1" pattern="$2" label="$3"
  TESTS=$((TESTS + 1))
  if [ -f "$file" ] && grep -qiE -- "$pattern" "$file"; then
    fail_msg "$label (unexpected match: $pattern)"
  else
    pass_msg "$label"
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
  'CALIB-TOTAL cost=<$> wall=<s> issues=<n> reftest-pass=<n>/<n> planted=<caught|missed|n/a>' \
  "CALIB-TOTAL line grammar"

echo ""
echo "docs/calibration.md — artifact + retro ingest"
assert_contains "$DOC" '$HARNESS/docs/retros/calib/<UTC date>T<HHMM>Z.txt' \
  "harness-rooted tee target (#1408)"
assert_contains "$DOC" 'run-retro.sh' "names the retro ingest script"
assert_contains "$DOC" 'weak-model pass' "ingest: weak-model pass row"
assert_contains "$DOC" 'median path b pr/usd' "ingest: median path b pr/usd computed value"

echo ""
echo "ingest described as implemented — weak-model pass"
for f in "$DOC" "$RETRO_README"; do
  n="$(basename "$(dirname "$f")")/$(basename "$f")"
  assert_matches "$f" 'count(ed|s)?[^.]*reftest=' \
    "$n: ratio is counted from the per-issue reftest= atoms"
  assert_not_matches "$f" 'ratio from [^.]*CALIB-TOTAL' \
    "$n: does not claim the ratio is read off CALIB-TOTAL"
  assert_matches "$f" 'CALIB-TOTAL.? (line )?is not parsed' \
    "$n: says the CALIB-TOTAL line is not parsed"
  assert_matches "$f" 'grammar carries no profile' \
    "$n: says the CALIB grammar has no profile/model/date atom"
  # #1395 flipped this row's polarity. The weak-model row USED to render as a
  # bare value with no provenance at all, so a cycle-12 retro could cite a
  # cycle-2 run and nothing said so. It now renders `<value> (run <date>)`, and
  # `<value> (run <date>, stale N cycles)` once N tracker cycle comments have
  # been posted since the run, at N >= 3. The date is read off the artifact
  # FILENAME, so `grammar carries no profile` above stays true and must stay
  # asserted — that is the distinction these two assertions pin together.
  assert_contains "$f" '(run <date>)' \
    "$n: the weak-model pass row renders the artifact's run date"
  assert_contains "$f" '(run <date>, stale N cycles)' \
    "$n: the weak-model pass row carries a stale-cycle marker"
  assert_matches "$f" '[Nn] ?(≥|>=) ?3' \
    "$n: names the N >= 3 threshold the stale marker fires at"
done

echo ""
echo "ingest described as implemented — median path b pr/usd"
for f in "$DOC" "$RETRO_README"; do
  n="$(basename "$(dirname "$f")")/$(basename "$f")"
  assert_matches "$f" 'path=B.? rows only' "$n: median reads path=B rows only"
  assert_matches "$f" 'apportion(ed|s|ment)[^.]*token' \
    "$n: cost= is a token-share apportionment of the priced total"
  assert_matches "$f" 'estimate, not a measured per-issue charge' \
    "$n: the per-issue dollar figure is flagged approximate"
done

echo ""
echo "docs/calibration.md — abort, harness staging, launch env (#1285)"
assert_contains "$DOC" 'CALIB-ABORT reason=<no-pr|held|timeout|no-cost-log>' \
  "CALIB-ABORT line grammar"
assert_contains "$DOC" 'calib/harness' "names the staged harness location"
assert_matches "$DOC" 'detached[^.]*worktree' "staging is a detached git worktree"
assert_contains "$DOC" 'env -u ALLOW_ORCHESTRATOR_EDIT' \
  "launch env unsets the orchestrator-edit override"
assert_contains "$DOC" 'PIPELINE_HEADLESS=true' "launch env sets the headless marker"
assert_contains "$DOC" 'T<HHMM>Z.log' "names the run-log artifact beside the .txt (#1408)"
assert_matches "$DOC" 'run #1|run 1' "records the run #1 lesson"
assert_matches "$DOC" 'run #2|run 2' "records the run #2 lesson"

echo ""
echo "docs/calibration.md — PIPELINE_* token set"
# The doc may name only knobs pipeline.config.example declares plus the two
# allow-listed injected vars (PIPELINE_HEADLESS, PIPELINE_TRUST_PROFILE); a
# removed/inert knob name here would red scripts/check-config-drift.sh.
# PIPELINE_PATH_B_MODEL_EXECUTE joined the list with the --executor-model arm
# (#1414): the doc names it because the flag sets it, and
# pipeline.config.example declares it (line ~401).
TESTS=$((TESTS + 1))
extra=""
if [ -f "$DOC" ]; then
  extra="$(grep -oE '\bPIPELINE_[A-Z0-9_]+\b' "$DOC" | sort -u \
    | grep -vxF -e PIPELINE_CALIB_DIR -e PIPELINE_CALIB_REPO \
        -e PIPELINE_CALIB_TIMEOUT -e PIPELINE_HEADLESS -e PIPELINE_TRUST_PROFILE \
        -e PIPELINE_PATH_B_MODEL_EXECUTE \
    | tr '\n' ' ' | sed 's/ $//')" || extra=""
fi
if [ -z "$extra" ]; then
  pass_msg "names no PIPELINE_* token beyond the three calib knobs, PIPELINE_HEADLESS, PIPELINE_TRUST_PROFILE and PIPELINE_PATH_B_MODEL_EXECUTE"
else
  fail_msg "names undeclared PIPELINE_* token(s): $extra"
fi

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
assert_contains "$RETRO_README" 'CALIB-ABORT' "retros README documents CALIB-ABORT"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
