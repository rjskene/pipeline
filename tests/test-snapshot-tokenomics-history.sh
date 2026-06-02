#!/usr/bin/env bash
# test-snapshot-tokenomics-history.sh — #832 regression guard.
#
# scripts/snapshot-tokenomics-history.sh invokes cost-latency-report.sh
# --emit-day-json and upserts each day object into a persisted per-day store
# (.claude/logs/tokenomics-history.jsonl), keyed by `date` (last-write-wins, so
# lower-bound days reconcile UPWARD as totals grow). Gated behind
# PIPELINE_LOGS_ENABLED, mirroring capture-agent-costs.sh.
#
# Hermetic: builds throwaway project dirs + fixture capture slices; never the
# live host pipeline.config or live `gh`. Modeled on
# tests/test-capture-agent-cost-config-gate.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAP="$REPO_ROOT/scripts/snapshot-tokenomics-history.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# make_fixture <dir> — write a minimal --fixture slice (prs/pr/issue/capture)
# into <dir>. The capture records below place issue 260 across two days.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  printf '%s\n' '[{"number":160,"title":"feat: snap","additions":6,"deletions":4,"body":"Closes #260","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$dir/prs.json"
  printf '%s\n' '{"number":160,"additions":6,"deletions":4,"comments":[]}' > "$dir/pr-160.json"
  printf '%s\n' '{"number":260,"labels":[],"comments":[]}' > "$dir/issue-260.json"
  { echo '{"schema_version":1,"issue":"260","stage":"plan","session_id":"sn1","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"KSN1","ts_start":"2026-05-31T09:00:00Z","tokens":{"input":1000,"output":0,"cache_creation":0,"cache_read":0,"total":1000},"duration_ms":1000}'
    echo '{"schema_version":1,"issue":"260","stage":"execute","session_id":"sn2","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"KSN2","ts_start":"2026-06-01T10:00:00Z","tokens":{"input":2000,"output":0,"cache_creation":0,"cache_read":0,"total":2000},"duration_ms":1000}'
  } > "$dir/capture.jsonl"
}

# ---------------------------------------------------------------------------
# Scenario 1: gated no-op — PIPELINE_LOGS_ENABLED not 'true' → SKIP, no write.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 1: gated no-op (no write, SKIP marker)"
[ -f "$SNAP" ] && pass_msg "script file exists" || fail_msg "script missing at scripts/snapshot-tokenomics-history.sh"

PROJ_OFF="$WORK/proj-off"
mkdir -p "$PROJ_OFF/.claude/logs"
STORE_OFF="$PROJ_OFF/.claude/logs/tokenomics-history.jsonl"

OUT_OFF="$(env -u PIPELINE_LOGS_ENABLED CLAUDE_PROJECT_DIR="$PROJ_OFF" bash "$SNAP" 2>/dev/null)"
RC_OFF=$?
[ "$RC_OFF" -eq 0 ] && pass_msg "gated-off (env unset) exits 0" || fail_msg "gated-off exited non-zero (rc=$RC_OFF)"
printf '%s' "$OUT_OFF" | grep -q 'SKIP_LOGGING_DISABLED' && pass_msg "gated-off prints SKIP_LOGGING_DISABLED marker" || fail_msg "gated-off missing SKIP_LOGGING_DISABLED marker (got: $OUT_OFF)"
[ ! -f "$STORE_OFF" ] && pass_msg "gated-off wrote NO store file" || fail_msg "gated-off wrote a store file (must be no-op)"

OUT_FALSE="$(PIPELINE_LOGS_ENABLED=false CLAUDE_PROJECT_DIR="$PROJ_OFF" bash "$SNAP" 2>/dev/null)"
RC_FALSE=$?
[ "$RC_FALSE" -eq 0 ] && pass_msg "gated-off (=false) exits 0" || fail_msg "gated-off (=false) exited non-zero (rc=$RC_FALSE)"
printf '%s' "$OUT_FALSE" | grep -q 'SKIP_LOGGING_DISABLED' && pass_msg "gated-off (=false) prints SKIP marker" || fail_msg "gated-off (=false) missing SKIP marker"
[ ! -f "$STORE_OFF" ] && pass_msg "gated-off (=false) wrote NO store file" || fail_msg "gated-off (=false) wrote a store file"

# ---------------------------------------------------------------------------
# Scenario 2: idempotent by day — two runs over the same fixture → one line/day.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 2: idempotent by day"
PROJ2="$WORK/proj2"
mkdir -p "$PROJ2/.claude/logs"
FIX2="$WORK/fix2"; make_fixture "$FIX2"
STORE2="$PROJ2/.claude/logs/tokenomics-history.jsonl"

PIPELINE_LOGS_ENABLED=true CLAUDE_PROJECT_DIR="$PROJ2" bash "$SNAP" \
  --fixture "$FIX2" --since 2026-05-31 --until 2026-06-01 >/dev/null 2>&1
RC2A=$?
[ "$RC2A" -eq 0 ] && pass_msg "first run exits 0" || fail_msg "first run exited non-zero (rc=$RC2A)"
[ -f "$STORE2" ] && pass_msg "first run wrote the store" || fail_msg "first run did NOT write the store"
LINES2A="$(wc -l < "$STORE2" 2>/dev/null | tr -d ' ')"
[ "$LINES2A" = "2" ] && pass_msg "store has 2 day lines after first run" || fail_msg "expected 2 lines after first run, got $LINES2A"

PIPELINE_LOGS_ENABLED=true CLAUDE_PROJECT_DIR="$PROJ2" bash "$SNAP" \
  --fixture "$FIX2" --since 2026-05-31 --until 2026-06-01 >/dev/null 2>&1
LINES2B="$(wc -l < "$STORE2" 2>/dev/null | tr -d ' ')"
[ "$LINES2B" = "2" ] && pass_msg "store still has 2 day lines after second run (idempotent)" || fail_msg "second run changed line count: $LINES2B (expected 2)"
UNIQ2="$(jq -s 'map(.date) | (length == (unique | length))' "$STORE2" 2>/dev/null)"
[ "$UNIQ2" = "true" ] && pass_msg "one line per distinct day (no dup dates)" || fail_msg "duplicate dates present in store"

# ---------------------------------------------------------------------------
# Scenario 3: reconcile-upward — a seeded LOW floor row is replaced upward.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 3: reconcile-upward (last-write-wins by day)"
PROJ3="$WORK/proj3"
mkdir -p "$PROJ3/.claude/logs"
STORE3="$PROJ3/.claude/logs/tokenomics-history.jsonl"
# Seed a LOW floor row for 2026-05-31 + an unrelated day to prove preservation.
{ echo '{"date":"2026-05-31","n":1,"tokens":{"input":10,"output":0,"cache_creation":0,"cache_read":0,"total":10},"per_n":{"input":10,"output":0,"cache_creation":0,"cache_read":0,"total":10},"active_loc":null,"per_loc":null,"priced_n":1,"cost":{"input":0,"output":0,"cache_creation":0,"cache_read":0,"total":0.00015},"cost_per_n":0.00015,"cost_per_loc":null,"usage_complete_floor":true}'
  echo '{"date":"2026-05-15","n":3,"tokens":{"input":50,"output":0,"cache_creation":0,"cache_read":0,"total":50},"per_n":{"input":16.6667,"output":0,"cache_creation":0,"cache_read":0,"total":16.6667},"active_loc":null,"per_loc":null,"priced_n":3,"cost":{"input":0,"output":0,"cache_creation":0,"cache_read":0,"total":0.00075},"cost_per_n":0.00025,"cost_per_loc":null,"usage_complete_floor":false}'
} > "$STORE3"
FIX3="$WORK/fix3"; make_fixture "$FIX3"
PIPELINE_LOGS_ENABLED=true CLAUDE_PROJECT_DIR="$PROJ3" bash "$SNAP" \
  --fixture "$FIX3" --since 2026-05-31 --until 2026-06-01 >/dev/null 2>&1
# 2026-05-31 now reconciled upward: tokens.total 10 → 1000, floor flips false.
NEW_TOTAL="$(jq -s 'map(select(.date=="2026-05-31"))[0].tokens.total' "$STORE3" 2>/dev/null)"
[ "$NEW_TOTAL" = "1000" ] && pass_msg "2026-05-31 reconciled upward (10 → 1000)" || fail_msg "2026-05-31 not reconciled, total=$NEW_TOTAL (expected 1000)"
NEW_FLOOR="$(jq -s 'map(select(.date=="2026-05-31"))[0].usage_complete_floor' "$STORE3" 2>/dev/null)"
[ "$NEW_FLOOR" = "false" ] && pass_msg "2026-05-31 floor flipped to false" || fail_msg "2026-05-31 floor still $NEW_FLOOR (expected false)"
DUP31="$(jq -s 'map(select(.date=="2026-05-31")) | length' "$STORE3" 2>/dev/null)"
[ "$DUP31" = "1" ] && pass_msg "exactly one row for the reconciled day (no duplicate)" || fail_msg "expected 1 row for 2026-05-31, got $DUP31"
# Unrelated pre-existing day preserved untouched.
PRES="$(jq -s 'map(select(.date=="2026-05-15"))[0].tokens.total' "$STORE3" 2>/dev/null)"
[ "$PRES" = "50" ] && pass_msg "pre-existing unrelated day (2026-05-15) preserved" || fail_msg "2026-05-15 not preserved, total=$PRES (expected 50)"

# ---------------------------------------------------------------------------
# Scenario 4: append new days — a new day is added, others untouched.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 4: append new days"
NEW_DAY="$(jq -s 'map(select(.date=="2026-06-01")) | length' "$STORE3" 2>/dev/null)"
[ "$NEW_DAY" = "1" ] && pass_msg "new day (2026-06-01) appended to store" || fail_msg "2026-06-01 not appended, count=$NEW_DAY"
DATES_SORTED="$(jq -rs 'map(.date) | (. == (sort))' "$STORE3" 2>/dev/null)"
[ "$DATES_SORTED" = "true" ] && pass_msg "store is sorted ascending by date" || fail_msg "store not sorted by date"

# ---------------------------------------------------------------------------
# Scenario 5: seed-day reproduction — aggregates match hand-computed figures.
# A faithful synthetic single-day slice; expectations derived by hand. See the
# seed-doc Reproduction block (docs/tokenomics-history-2026-05-29-to-06-02.md):
# this guards that the snapshot math (Task 1 emit + Task 4 upsert) reproduces a
# per-day aggregate from the raw capture log.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 5: seed-day reproduction guard"
PROJ5="$WORK/proj5"
mkdir -p "$PROJ5/.claude/logs"
STORE5="$PROJ5/.claude/logs/tokenomics-history.jsonl"
FIX5="$WORK/fix5"; mkdir -p "$FIX5"
printf '%s\n' '[{"number":165,"title":"feat: seed","additions":12,"deletions":8,"body":"Closes #265","mergedAt":"2026-05-30T12:00:00Z","labels":[]}]' > "$FIX5/prs.json"
printf '%s\n' '{"number":165,"additions":12,"deletions":8,"comments":[]}' > "$FIX5/pr-165.json"
printf '%s\n' '{"number":265,"labels":[],"comments":[]}' > "$FIX5/issue-265.json"
# One seed day (2026-05-30): 3 priced opus records + 1 unpriced.
#  input tokens: 3000 (priced) + 1000 (priced) + 0 + 500 (unpriced) = 4500
#  output tokens: 0 + 0 + 2000 + 0 = 2000
#  tokens.total = 4500 + 2000 = 6500 ; n = 4 ; priced_n = 3
#  cost = (3000+1000)/1e6*15 + 2000/1e6*75 = 0.06 + 0.15 = 0.21
{ echo '{"schema_version":1,"issue":"265","stage":"plan","session_id":"sd1","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"KSD1","ts_start":"2026-05-30T08:00:00Z","tokens":{"input":3000,"output":0,"cache_creation":0,"cache_read":0,"total":3000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"265","stage":"plan-eval","session_id":"sd2","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"KSD2","ts_start":"2026-05-30T09:00:00Z","tokens":{"input":1000,"output":0,"cache_creation":0,"cache_read":0,"total":1000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"265","stage":"execute","session_id":"sd3","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"KSD3","ts_start":"2026-05-30T10:00:00Z","tokens":{"input":0,"output":2000,"cache_creation":0,"cache_read":0,"total":2000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"265","stage":"pr-eval","session_id":"sd4","model":"","agent_kind":"inline","usage_complete":true,"record_key":"KSD4","ts_start":"2026-05-30T11:00:00Z","tokens":{"input":500,"output":0,"cache_creation":0,"cache_read":0,"total":500},"duration_ms":1000}'
} > "$FIX5/capture.jsonl"
PIPELINE_LOGS_ENABLED=true CLAUDE_PROJECT_DIR="$PROJ5" bash "$SNAP" \
  --fixture "$FIX5" --since 2026-05-30 --until 2026-05-30 >/dev/null 2>&1
SD="$(jq -s 'map(select(.date=="2026-05-30"))[0]' "$STORE5" 2>/dev/null)"
sd_get() { printf '%s' "$SD" | jq -r "$1" 2>/dev/null; }
[ "$(sd_get '.n')" = "4" ] && pass_msg "seed day n==4" || fail_msg "seed day n expected 4, got $(sd_get '.n')"
[ "$(sd_get '.priced_n')" = "3" ] && pass_msg "seed day priced_n==3" || fail_msg "seed day priced_n expected 3, got $(sd_get '.priced_n')"
[ "$(sd_get '.tokens.total')" = "6500" ] && pass_msg "seed day tokens.total==6500" || fail_msg "seed day tokens.total expected 6500, got $(sd_get '.tokens.total')"
[ "$(sd_get '.tokens.input')" = "4500" ] && pass_msg "seed day tokens.input==4500" || fail_msg "seed day tokens.input expected 4500, got $(sd_get '.tokens.input')"
[ "$(sd_get '.tokens.output')" = "2000" ] && pass_msg "seed day tokens.output==2000" || fail_msg "seed day tokens.output expected 2000, got $(sd_get '.tokens.output')"
if awk -v c="$(sd_get '.cost.total')" 'BEGIN{exit !(c>0.209 && c<0.211)}'; then pass_msg "seed day cost.total ~= 0.21"; else fail_msg "seed day cost.total expected ~0.21, got $(sd_get '.cost.total')"; fi
# active_loc: issue 265 (loc 20) has records that day → active_loc=20.
[ "$(sd_get '.active_loc')" = "20" ] && pass_msg "seed day active_loc==20 (issue 265 LOC join)" || fail_msg "seed day active_loc expected 20, got $(sd_get '.active_loc')"

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
