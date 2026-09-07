#!/bin/bash
set -uo pipefail
#
# Tests for scripts/run-retro.sh `--post` per-issue AGENT-COST rows and the
# agent-cost backfill that feeds them (issue #1293, tracker #1271).
#
# Step 5 of the evolve loop reads `--post` to decide whether a cycle's issues
# earned their spend, but `--post` today prints no cost at all: the operator
# compares an empty table against the scorecard's `23M tokens` median PATH B
# PR. This file pins the rows, the rollup, the degradation strings and the
# backfill gate that close that gap.
#
# Substrate: the shared tests/fixtures/run-retro/ tree — including the new
# agent-costs.jsonl — copied to a temp dir per scenario. The shared dir is
# NEVER mutated (tests/test-run-retro.sh Scenario 15 asserts the `--post`
# tree is byte-identical after a run, and the calib-ingest test states the
# copy-before-mutate rule). See tests/fixtures/run-retro/README.md for the
# numbers pinned below and why each control moves the median to a value no
# other bug produces.
#
# The rollup contract, in one line: dedup on `record_key` FIRST
# (`group_by(.record_key) | map(last)` — the key is LOGICAL and legitimately
# RECURS with revised totals, per the schema header in capture-agent-costs.sh),
# THEN keep records whose `.issue` (a STRING) parses to a cycle issue number,
# THEN sum `.tokens.total` and count distinct `.stage` per issue.
#
# BEHAVIOUR TEST ONLY — nothing here greps SKILL.md / CLAUDE.md prose.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/run-retro.sh"
FIXTURE_DIR="$ROOT/tests/fixtures/run-retro"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# mkfix <name> [rm=<basename>]...  — same shape as tests/test-run-retro.sh's
# helper: copy the shared fixture to a temp dir, then drop named files.
mkfix() {
  local name="$1"; shift
  local dir="$TMP_ROOT/$name"
  rm -rf "$dir"
  cp -r "$FIXTURE_DIR" "$dir"
  while [ $# -gt 0 ]; do
    case "$1" in
      rm=*) rm -f "$dir/${1#rm=}" ;;
    esac
    shift
  done
  printf '%s' "$dir"
}

expect_line() { # <label> <text> <exact line>
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then pass_msg "$1"; else
    fail_msg "$1 (missing line: $3)"
  fi
}
refute_sub() { # <label> <text> <fixed substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail_msg "$1 (unexpectedly present: $3)"; else
    pass_msg "$1"
  fi
}

# ---------------------------------------------------------------------------
scenario "Scenario 0: the fixture substrate exists and carries the pinned records"
# ---------------------------------------------------------------------------
if [ -f "$FIXTURE_DIR/agent-costs.jsonl" ]; then
  pass_msg "tests/fixtures/run-retro/agent-costs.jsonl exists"
else
  fail_msg "tests/fixtures/run-retro/agent-costs.jsonl missing — every assertion below is vacuous"
fi
NREC="$(wc -l < "$FIXTURE_DIR/agent-costs.jsonl" 2>/dev/null | tr -d '[:space:]')"
if [ "${NREC:-0}" -eq 6 ]; then
  pass_msg "substrate carries 6 records"
else
  fail_msg "substrate should carry 6 records, got ${NREC:-0}"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 1: --post emits one cost row per cycle issue, plus the median"
# ---------------------------------------------------------------------------
FIX1="$(mkfix cost-rows)"
OUT1="$(bash "$HELPER" --cycle 0 --post --fixture "$FIX1" 2>/dev/null)"

# NON-VACUITY FIRST: the refutes further down pass on empty output.
if printf '%s\n' "$OUT1" | grep -q '^cost:'; then
  pass_msg "--post emits at least one cost: line"
else
  fail_msg "--post emits no cost: line at all"
fi

# #1272 — two DISTINCT record_keys, stages plan + execute: 10M + 20M = 30M / 2 stages.
expect_line "#1272 row sums both records and counts both stages" "$OUT1" \
  "cost: issue=#1272 tokens=30000000 stages=2"
# #1273 — two lines sharing ONE record_key (999M then 50M). The dedup keeps the
# LAST, so the row is 50M. This row IS the record_key control.
expect_line "#1273 row is the record_key-deduped total (last write wins)" "$OUT1" \
  "cost: issue=#1273 tokens=50000000 stages=1"
# #1274 — a single pr-eval record.
expect_line "#1274 row renders a single-record issue" "$OUT1" \
  "cost: issue=#1274 tokens=70000000 stages=1"
expect_line "median over the three per-issue totals" "$OUT1" \
  "cost: loop-own tokens/issue median = 50000000"
expect_line "backfill breadcrumb names the fixture-mode skip" "$OUT1" \
  "cost: backfill = skipped (fixture mode)"

# ---------------------------------------------------------------------------
scenario "Scenario 2: record_key dedup control"
# ---------------------------------------------------------------------------
# Summing #1273's two same-key lines without deduping gives 1049000000 and
# moves the median to 70000000 — both distinct from every other value the
# fixture can produce, so this control cannot pass by coincidence.
refute_sub "#1273's superseded 999000000 record is not summed in" "$OUT1" "tokens=1049000000"
refute_sub "the superseded lower-bound total never reaches a row" "$OUT1" "tokens=999000000"
refute_sub "the median is not the dedup-skipped 70000000" "$OUT1" \
  "cost: loop-own tokens/issue median = 70000000"

# ---------------------------------------------------------------------------
scenario "Scenario 3: out-of-cycle leak control"
# ---------------------------------------------------------------------------
# #9999 carries 900000000 tokens and is in NO cycle-0 block. Including it would
# render a fourth row and move the median to 60000000.
refute_sub "no row for the out-of-cycle issue #9999" "$OUT1" "cost: issue=#9999"
refute_sub "the out-of-cycle total never reaches a row" "$OUT1" "tokens=900000000"
refute_sub "the median is not the leaked-in 60000000" "$OUT1" \
  "cost: loop-own tokens/issue median = 60000000"
NROWS="$(printf '%s\n' "$OUT1" | grep -c '^cost: issue=#')"
if [ "$NROWS" -eq 3 ]; then
  pass_msg "exactly 3 cost rows — one per cycle-0 issue"
else
  fail_msg "expected 3 cost rows (one per cycle-0 issue), got $NROWS"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 4: removed-substrate degradation (never fail the retro)"
# ---------------------------------------------------------------------------
FIX2="$(mkfix no-costs rm=agent-costs.jsonl)"
OUT2="$(bash "$HELPER" --cycle 0 --post --fixture "$FIX2" 2>/dev/null)"
RC2=$?
if [ "$RC2" -eq 0 ]; then
  pass_msg "--post still exits 0 with the agent-costs substrate removed"
else
  fail_msg "--post exited $RC2 with the substrate removed (degradation contract: never fail)"
fi
expect_line "#1272 row degrades to the pinned no-substrate string" "$OUT2" \
  "cost: issue=#1272 n/a (no agent-costs substrate)"
expect_line "#1273 row degrades to the pinned no-substrate string" "$OUT2" \
  "cost: issue=#1273 n/a (no agent-costs substrate)"
expect_line "#1274 row degrades to the pinned no-substrate string" "$OUT2" \
  "cost: issue=#1274 n/a (no agent-costs substrate)"
expect_line "median degrades to the pinned no-substrate string" "$OUT2" \
  "cost: loop-own tokens/issue median = n/a (no agent-costs substrate)"
expect_line "breadcrumb still names the fixture-mode skip" "$OUT2" \
  "cost: backfill = skipped (fixture mode)"

# ---------------------------------------------------------------------------
scenario "Scenario 5: --post writes nothing to the fixture tree"
# ---------------------------------------------------------------------------
FIX3="$(mkfix tree-guard)"
TREE_BEFORE="$(find "$FIX3" -type f -exec md5sum {} + | sort)"
bash "$HELPER" --cycle 0 --post --fixture "$FIX3" >/dev/null 2>&1
TREE_AFTER="$(find "$FIX3" -type f -exec md5sum {} + | sort)"
if [ "$TREE_BEFORE" = "$TREE_AFTER" ]; then
  pass_msg "--post leaves the fixture tree byte-identical (the backfill must not run in fixture mode)"
else
  fail_msg "--post modified the fixture tree"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 6: live-mode backfill gate — NEGATIVE (logging disabled)"
# ---------------------------------------------------------------------------
# LIVE mode (no --fixture) with PIPELINE_REPO unset: every `gh` fetch is
# skipped, so the run is fully offline. CLAUDE_PROJECT_DIR points at a fresh
# non-git temp dir, which is exactly the fail-open path capture-agent-costs.sh
# takes when it cannot resolve a main worktree — so the backfill's output
# lands under $TMPPROJ or nowhere.
TMPPROJ_OFF="$TMP_ROOT/proj-off"
mkdir -p "$TMPPROJ_OFF"
env -u PIPELINE_REPO PIPELINE_LOGS_ENABLED=false CLAUDE_PROJECT_DIR="$TMPPROJ_OFF" \
  bash "$HELPER" --cycle 0 --post >/dev/null 2>&1
if [ -e "$TMPPROJ_OFF/.claude/logs/agent-costs.jsonl" ]; then
  fail_msg "PIPELINE_LOGS_ENABLED=false still produced an agent-costs log (the gate leaks)"
else
  pass_msg "PIPELINE_LOGS_ENABLED=false writes no agent-costs log"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 7: live-mode backfill gate — POSITIVE (logging enabled)"
# ---------------------------------------------------------------------------
# Paired with Scenario 6: without this half, "no file created" would hold
# vacuously for a build that never runs the backfill at all.
TMPPROJ_ON="$TMP_ROOT/proj-on"
mkdir -p "$TMPPROJ_ON"
OUT_ON="$(env -u PIPELINE_REPO PIPELINE_LOGS_ENABLED=true CLAUDE_PROJECT_DIR="$TMPPROJ_ON" \
  bash "$HELPER" --cycle 0 --post 2>/dev/null)"
if [ -e "$TMPPROJ_ON/.claude/logs/agent-costs.jsonl" ]; then
  pass_msg "PIPELINE_LOGS_ENABLED=true runs the backfill (agent-costs log created)"
else
  fail_msg "PIPELINE_LOGS_ENABLED=true produced no agent-costs log — the backfill never ran"
fi
expect_line "breadcrumb reports the backfill ran" "$OUT_ON" "cost: backfill = ran"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
