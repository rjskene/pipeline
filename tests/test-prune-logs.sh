#!/bin/bash
set -uo pipefail

# Tests for scripts/prune-logs.sh (issue #1353) — the retention pass over
# .claude/logs/ that is DRY RUN by default, keep-list-first, and whose
# --apply path is gated behind the repo's existing ALLOW_DELETIONS convention.
#
# Contract under test (from the approved plan):
#   bash scripts/prune-logs.sh [--apply] [--days N]
#   * retention resolution, first wins: --days N > PIPELINE_LOGS_RETENTION_DAYS > 30
#   * log dir resolution, first wins: PIPELINE_PROJECT_ROOT > CLAUDE_PROJECT_DIR >
#     main-worktree root (git rev-parse --git-common-dir parent) > pwd;
#     logs dir is <root>/.claude/logs
#   * keep-list is checked BEFORE any prune glob (a new aggregate is safe only
#     if listed there, or if it matches no prune glob at all)
#   * age_days = floor((now - mtime) / 86400); candidate iff age_days > RETENTION
#   * one `PRUNE path=<rel> age_days=<n>` line per candidate, then exactly one
#     `SUMMARY candidates=<n> bytes=<n> mode=dry-run` (or `SUMMARY deleted=<n>
#     bytes=<n> mode=apply`) line; exit 0 on every non-usage path
#   * unknown flag / non-integer --days → exit 2, usage on stderr
#
# Strategy: hermetic fixture root under mktemp -d (NOT a git repo — the script
# must fail open to the resolved root), ages stamped with exact epoch seconds so
# the floor()-based boundary case is deterministic, and every invocation pinned
# with PIPELINE_PROJECT_ROOT=<fixture>. Nothing outside $TMP is ever touched.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/prune-logs.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

NOW=$(date +%s)

summary_line() { grep -E '^SUMMARY ' "$1" | tail -1; }

# run_prune <root> <outfile> <errfile> [env assignments...] -- [args...]
# Always clears ALLOW_DELETIONS from the ambient environment; callers that want
# the gate open pass ALLOW_DELETIONS=true explicitly.
run_prune() {
  local root="$1" out="$2" err="$3"; shift 3
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -u ALLOW_DELETIONS -u CLAUDE_PROJECT_DIR -u PIPELINE_LOGS_RETENTION_DAYS \
    PIPELINE_PROJECT_ROOT="$root" ${envs[@]+"${envs[@]}"} \
    bash "$SCRIPT" "$@" >"$out" 2>"$err"
  return $?
}

# mk <root> <rel-path> <age-days>
# 10-byte payload so `bytes=` totals are exact multiples of 10.
mk() {
  local root="$1" rel="$2" days="$3"
  local f="$root/.claude/logs/$rel"
  mkdir -p "$(dirname "$f")"
  printf '0123456789' > "$f"
  touch -d "@$(( NOW - days * 86400 ))" "$f"
}

KEEP_FILES=(
  agent-costs.jsonl
  tokenomics-history.jsonl
  usage-gate.jsonl
  metrics-timeseries.jsonl
  metrics-snapshot.cron.log
  agent-cost-orchestrator-state.json
  tool-use.log
  subagents.log
  runs.log
  hook-errors.log
  dogfood-refresh.log
  plan-drafts/issue-42-draft.md
)

PRUNE_FILES=(
  issue-42-20250501-120000.log
  issue-42-plan.md
  issue-42-eval.log
  issue-42-execute.log
  queue-20250501-120000.log
  tool-use-issue-42.log
  ci-fix-42-attempt-1.log
  fullsend-20250501-120000.out
  runner-2.log
  analyze-shortlist-20250501.json
  subagents/nested/deep-agent.jsonl
)

# new_fixture <name> → echoes the fixture root; ages every keep-list AND
# prune-set file to 400 days (well past any retention window used here).
new_fixture() {
  local root="$TMP/$1"
  mkdir -p "$root/.claude/logs"
  local f
  for f in "${KEEP_FILES[@]}"; do mk "$root" "$f" 400; done
  for f in "${PRUNE_FILES[@]}"; do mk "$root" "$f" 400; done
  # Unrecognized legacy file: matches neither list → must be left alone.
  mk "$root" "legacy-unknown-artifact.log" 400
  echo "$root"
}

count_files() { find "$1/.claude/logs" -type f 2>/dev/null | wc -l; }

echo "prune-logs.sh: #1353 retention pass"

# ---- Case 0: the script exists ------------------------------------------
echo "Case 0: scripts/prune-logs.sh is present"
inc
if [ -f "$SCRIPT" ]; then
  pass_msg "script present at scripts/prune-logs.sh"
else
  fail_msg "script missing at scripts/prune-logs.sh"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  echo "RESULT: FAIL"
  exit 1
fi

# ---- Case A: dry run lists prune-set only, deletes nothing ---------------
echo "Case A: dry run lists aged prune-set files only"
ROOT_A="$(new_fixture a)"
BEFORE_A="$(count_files "$ROOT_A")"
run_prune "$ROOT_A" "$TMP/a.out" "$TMP/a.err" --
RC_A=$?

inc
if [ "$RC_A" -eq 0 ]; then
  pass_msg "dry run exits 0"
else
  fail_msg "dry run exited $RC_A; expected 0 (stderr: $(head -3 "$TMP/a.err" | tr '\n' ' '))"
fi

inc
MISSING_A=""
for f in "${PRUNE_FILES[@]}"; do
  grep -Fq "PRUNE path=$f age_days=" "$TMP/a.out" || MISSING_A="$MISSING_A $f"
done
if [ -z "$MISSING_A" ]; then
  pass_msg "every aged prune-set file emits a PRUNE line with age_days="
else
  fail_msg "missing PRUNE lines for:$MISSING_A"
fi

inc
LEAKED_A=""
for f in "${KEEP_FILES[@]}"; do
  grep -Fq "PRUNE path=$f " "$TMP/a.out" && LEAKED_A="$LEAKED_A $f"
done
grep -Fq "PRUNE path=legacy-unknown-artifact.log " "$TMP/a.out" && \
  LEAKED_A="$LEAKED_A legacy-unknown-artifact.log"
if [ -z "$LEAKED_A" ]; then
  pass_msg "no keep-list (or unrecognized) file is ever a candidate"
else
  fail_msg "keep-list/unrecognized files listed as candidates:$LEAKED_A"
fi

inc
EXPECT_N=${#PRUNE_FILES[@]}
EXPECT_BYTES=$(( EXPECT_N * 10 ))
if [ "$(summary_line "$TMP/a.out")" = "SUMMARY candidates=$EXPECT_N bytes=$EXPECT_BYTES mode=dry-run" ]; then
  pass_msg "SUMMARY candidates=$EXPECT_N bytes=$EXPECT_BYTES mode=dry-run"
else
  fail_msg "summary was '$(summary_line "$TMP/a.out")'; expected 'SUMMARY candidates=$EXPECT_N bytes=$EXPECT_BYTES mode=dry-run'"
fi

inc
if [ "$(grep -cE '^SUMMARY ' "$TMP/a.out")" = "1" ]; then
  pass_msg "exactly one SUMMARY line"
else
  fail_msg "expected exactly 1 SUMMARY line, found $(grep -cE '^SUMMARY ' "$TMP/a.out")"
fi

inc
if [ "$(count_files "$ROOT_A")" = "$BEFORE_A" ]; then
  pass_msg "dry run deletes nothing ($BEFORE_A files still present)"
else
  fail_msg "dry run changed the fixture: $BEFORE_A → $(count_files "$ROOT_A") files"
fi

# ---- Case B: --apply without ALLOW_DELETIONS deletes nothing -------------
echo "Case B: --apply with the ALLOW_DELETIONS gate closed"
ROOT_B="$(new_fixture b)"
BEFORE_B="$(count_files "$ROOT_B")"
run_prune "$ROOT_B" "$TMP/b.out" "$TMP/b.err" -- --apply
RC_B=$?

inc
if [ "$RC_B" -eq 0 ]; then
  pass_msg "gate-blocked --apply exits 0"
else
  fail_msg "gate-blocked --apply exited $RC_B; expected 0"
fi

inc
if [ "$(count_files "$ROOT_B")" = "$BEFORE_B" ]; then
  pass_msg "gate-blocked --apply deletes nothing"
else
  fail_msg "gate-blocked --apply deleted files: $BEFORE_B → $(count_files "$ROOT_B")"
fi

inc
if summary_line "$TMP/b.out" | grep -q 'mode=dry-run'; then
  pass_msg "gate-blocked --apply reports mode=dry-run"
else
  fail_msg "gate-blocked summary was '$(summary_line "$TMP/b.out")'; expected mode=dry-run"
fi

inc
if grep -q 'ALLOW_DELETIONS' "$TMP/b.err"; then
  pass_msg "gate notice naming ALLOW_DELETIONS written to stderr"
else
  fail_msg "no ALLOW_DELETIONS gate notice on stderr"
fi

# ---- Case C: --apply with the gate open deletes exactly the candidates ---
echo "Case C: --apply with ALLOW_DELETIONS=true"
ROOT_C="$(new_fixture c)"
run_prune "$ROOT_C" "$TMP/c.out" "$TMP/c.err" ALLOW_DELETIONS=true -- --apply
RC_C=$?

inc
if [ "$RC_C" -eq 0 ]; then
  pass_msg "--apply exits 0"
else
  fail_msg "--apply exited $RC_C; expected 0"
fi

inc
STILL_C=""
for f in "${PRUNE_FILES[@]}"; do
  [ -e "$ROOT_C/.claude/logs/$f" ] && STILL_C="$STILL_C $f"
done
if [ -z "$STILL_C" ]; then
  pass_msg "every aged prune-set file was deleted"
else
  fail_msg "--apply left candidates on disk:$STILL_C"
fi

inc
GONE_C=""
for f in "${KEEP_FILES[@]}" legacy-unknown-artifact.log; do
  [ -e "$ROOT_C/.claude/logs/$f" ] || GONE_C="$GONE_C $f"
done
if [ -z "$GONE_C" ]; then
  pass_msg "keep-list and unrecognized files survive --apply"
else
  fail_msg "--apply deleted protected files:$GONE_C"
fi

inc
if [ "$(summary_line "$TMP/c.out")" = "SUMMARY deleted=$EXPECT_N bytes=$EXPECT_BYTES mode=apply" ]; then
  pass_msg "SUMMARY deleted=$EXPECT_N bytes=$EXPECT_BYTES mode=apply"
else
  fail_msg "summary was '$(summary_line "$TMP/c.out")'; expected 'SUMMARY deleted=$EXPECT_N bytes=$EXPECT_BYTES mode=apply'"
fi

# ---- Case D: retention resolution (--days > knob > 30) -------------------
echo "Case D: --days override and PIPELINE_LOGS_RETENTION_DAYS knob"
ROOT_D="$TMP/d"
mkdir -p "$ROOT_D/.claude/logs"
mk "$ROOT_D" "queue-ten-day.log" 10
mk "$ROOT_D" "queue-forty-day.log" 40

inc
run_prune "$ROOT_D" "$TMP/d1.out" "$TMP/d1.err" -- --days 5
if grep -Fq 'PRUNE path=queue-ten-day.log age_days=10' "$TMP/d1.out"; then
  pass_msg "--days 5 makes a 10-day file a candidate"
else
  fail_msg "--days 5 did not list the 10-day file (out: $(summary_line "$TMP/d1.out"))"
fi

inc
run_prune "$ROOT_D" "$TMP/d2.out" "$TMP/d2.err" PIPELINE_LOGS_RETENTION_DAYS=90 --
if ! grep -Fq 'PRUNE path=queue-forty-day.log' "$TMP/d2.out"; then
  pass_msg "PIPELINE_LOGS_RETENTION_DAYS=90 keeps a 40-day file safe"
else
  fail_msg "PIPELINE_LOGS_RETENTION_DAYS=90 still pruned the 40-day file"
fi

inc
if [ "$(summary_line "$TMP/d2.out")" = "SUMMARY candidates=0 bytes=0 mode=dry-run" ]; then
  pass_msg "knob=90 yields candidates=0"
else
  fail_msg "knob=90 summary was '$(summary_line "$TMP/d2.out")'; expected candidates=0"
fi

inc
run_prune "$ROOT_D" "$TMP/d3.out" "$TMP/d3.err" PIPELINE_LOGS_RETENTION_DAYS=90 -- --days 5
if grep -Fq 'PRUNE path=queue-forty-day.log' "$TMP/d3.out" && \
   grep -Fq 'PRUNE path=queue-ten-day.log' "$TMP/d3.out"; then
  pass_msg "--days 5 beats PIPELINE_LOGS_RETENTION_DAYS=90"
else
  fail_msg "--days did not override the knob (summary: $(summary_line "$TMP/d3.out"))"
fi

inc
run_prune "$ROOT_D" "$TMP/d4.out" "$TMP/d4.err" --
if [ "$(summary_line "$TMP/d4.out")" = "SUMMARY candidates=1 bytes=10 mode=dry-run" ] && \
   grep -Fq 'PRUNE path=queue-forty-day.log' "$TMP/d4.out"; then
  pass_msg "default retention is 30 days (40-day pruned, 10-day kept)"
else
  fail_msg "default-retention run was '$(summary_line "$TMP/d4.out")'; expected candidates=1 bytes=10"
fi

# ---- Case E: freshness and the strict > boundary -------------------------
echo "Case E: fresh file and the exact-retention boundary"
ROOT_E="$TMP/e"
mkdir -p "$ROOT_E/.claude/logs"
mk "$ROOT_E" "queue-fresh.log" 0
mk "$ROOT_E" "queue-exactly-30.log" 30
mk "$ROOT_E" "queue-thirty-one.log" 31
run_prune "$ROOT_E" "$TMP/e.out" "$TMP/e.err" --

inc
if ! grep -Fq 'PRUNE path=queue-fresh.log' "$TMP/e.out"; then
  pass_msg "a zero-day fresh file is never a candidate"
else
  fail_msg "fresh file was listed as a candidate"
fi

inc
if ! grep -Fq 'PRUNE path=queue-exactly-30.log' "$TMP/e.out"; then
  pass_msg "a file aged exactly RETENTION days survives (strict >)"
else
  fail_msg "boundary file aged exactly 30 days was pruned; candidate iff age_days > RETENTION"
fi

inc
if [ "$(summary_line "$TMP/e.out")" = "SUMMARY candidates=1 bytes=10 mode=dry-run" ] && \
   grep -Fq 'PRUNE path=queue-thirty-one.log age_days=31' "$TMP/e.out"; then
  pass_msg "only the 31-day file is a candidate"
else
  fail_msg "boundary run was '$(summary_line "$TMP/e.out")'; expected exactly the 31-day file"
fi

# ---- Case F: subagents/ at any depth vs top-level subagents.log ----------
echo "Case F: subagents/ subtree vs the subagents.log aggregate"
ROOT_F="$TMP/f"
mkdir -p "$ROOT_F/.claude/logs"
mk "$ROOT_F" "subagents.log" 400
mk "$ROOT_F" "subagents/shallow.jsonl" 400
mk "$ROOT_F" "subagents/a/b/c/deep.jsonl" 400
run_prune "$ROOT_F" "$TMP/f.out" "$TMP/f.err" --

inc
if grep -Fq 'PRUNE path=subagents/shallow.jsonl' "$TMP/f.out" && \
   grep -Fq 'PRUNE path=subagents/a/b/c/deep.jsonl' "$TMP/f.out"; then
  pass_msg "aged files under subagents/ are candidates at any depth"
else
  fail_msg "subagents/ subtree not fully enumerated (summary: $(summary_line "$TMP/f.out"))"
fi

inc
if ! grep -Fq 'PRUNE path=subagents.log' "$TMP/f.out"; then
  pass_msg "top-level subagents.log stays on the keep-list"
else
  fail_msg "subagents.log was listed as a candidate — it is a live aggregate stream"
fi

inc
if [ "$(summary_line "$TMP/f.out")" = "SUMMARY candidates=2 bytes=20 mode=dry-run" ]; then
  pass_msg "SUMMARY candidates=2 bytes=20 mode=dry-run"
else
  fail_msg "subagents run was '$(summary_line "$TMP/f.out")'; expected candidates=2 bytes=20"
fi

# ---- Case G: missing .claude/logs/ dir -----------------------------------
echo "Case G: missing .claude/logs/ directory"
ROOT_G="$TMP/g"
mkdir -p "$ROOT_G"
run_prune "$ROOT_G" "$TMP/g.out" "$TMP/g.err" --
RC_G=$?

inc
if [ "$RC_G" -eq 0 ]; then
  pass_msg "missing logs dir exits 0"
else
  fail_msg "missing logs dir exited $RC_G; expected 0"
fi

inc
if [ "$(summary_line "$TMP/g.out")" = "SUMMARY candidates=0 bytes=0 mode=dry-run" ]; then
  pass_msg "SUMMARY candidates=0 bytes=0 mode=dry-run"
else
  fail_msg "missing-logs-dir summary was '$(summary_line "$TMP/g.out")'; expected candidates=0 bytes=0 mode=dry-run"
fi

# ---- Case H: usage errors ------------------------------------------------
echo "Case H: unknown flag and non-integer --days"
ROOT_H="$TMP/h"
mkdir -p "$ROOT_H/.claude/logs"

inc
run_prune "$ROOT_H" "$TMP/h1.out" "$TMP/h1.err" -- --bogus
RC_H1=$?
if [ "$RC_H1" -eq 2 ]; then
  pass_msg "unknown flag exits 2"
else
  fail_msg "unknown flag exited $RC_H1; expected 2"
fi

inc
if [ -s "$TMP/h1.err" ]; then
  pass_msg "unknown flag writes usage to stderr"
else
  fail_msg "unknown flag wrote nothing to stderr"
fi

inc
run_prune "$ROOT_H" "$TMP/h2.out" "$TMP/h2.err" -- --days notanumber
RC_H2=$?
if [ "$RC_H2" -eq 2 ]; then
  pass_msg "non-integer --days exits 2"
else
  fail_msg "non-integer --days exited $RC_H2; expected 2"
fi

inc
run_prune "$ROOT_H" "$TMP/h3.out" "$TMP/h3.err" -- --help
RC_H3=$?
if [ "$RC_H3" -eq 0 ]; then
  pass_msg "--help exits 0"
else
  fail_msg "--help exited $RC_H3; expected 0"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
