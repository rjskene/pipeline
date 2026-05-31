#!/bin/bash
set -uo pipefail
#
# Tests for scripts/cost-latency-report.sh — dogfood-only cost & latency
# report (issue #643). Joins merged-PR data with #642's capture JSONL to
# surface tokens/LOC/time per issue & stage, per-PATH/per-stage aggregates,
# TOP-N consumers, and over-served outliers.
#
# Uses fixture mode (--fixture <dir>) so no live `gh` calls are required.
# The fixture directory must contain:
#   - prs.json        — synthetic `gh pr list ... --json number,title,...` payload
#   - pr-<N>.json     — synthetic `gh pr view <N> --json ...` payload (one per PR)
#   - issue-<N>.json  — synthetic `gh issue view <N> --json ...` payload (one per linked issue)
#   - capture.jsonl   — synthetic #642 capture records (one JSON object per line)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/cost-latency-report.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/cost-latency-report"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

inc_scenario() { echo ""; echo "-- $1 --"; }

# --- Scenario 1: scaffolding (script existence + shebang + --help banner) ---
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/cost-latency-report.sh"
else
  fail_msg "script file missing at scripts/cost-latency-report.sh"
fi

if [ -x "$HELPER" ]; then
  pass_msg "script is executable"
else
  fail_msg "script is not executable"
fi

if [ -f "$HELPER" ] && head -1 "$HELPER" | grep -q '^#!/bin/bash'; then
  pass_msg "script has #!/bin/bash shebang"
else
  fail_msg "script missing #!/bin/bash shebang"
fi

if [ -f "$HELPER" ]; then
  HELP_OUT="$(bash "$HELPER" --help 2>&1 || true)"
  if printf '%s' "$HELP_OUT" | grep -qi 'usage'; then
    pass_msg "--help prints usage banner"
  else
    fail_msg "--help did not print a usage banner (got: $(printf '%s' "$HELP_OUT" | head -1))"
  fi
  if printf '%s' "$HELP_OUT" | grep -qi 'DOGFOOD'; then
    pass_msg "--help banner mentions DOGFOOD"
  else
    fail_msg "--help banner missing DOGFOOD callout"
  fi
fi

# --- Scenario 2: fixture loaders produce JSON rows ---
# Uses the static fixture directory tests/fixtures/cost-latency-report which
# carries 4 eligible feature PRs (102→B, 302→B, 103→C, 104→D) plus a release
# PR (#901) that must be excluded, and a capture.jsonl with records for issues
# 202/402/203 (204 has none) plus an out-of-window record for issue 999.
inc_scenario "Scenario 2: fixture loaders emit JSON rows"

ROWS_OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-rows-json 2>/dev/null)"
ROWS_RC=$?
if [ "$ROWS_RC" -eq 0 ]; then
  pass_msg "fixture-mode --emit-rows-json exits 0"
else
  fail_msg "fixture-mode --emit-rows-json exited non-zero (rc=$ROWS_RC)"
fi

if printf '%s' "$ROWS_OUT" | jq -e . >/dev/null 2>&1; then
  pass_msg "--emit-rows-json output parses as JSON"
else
  fail_msg "--emit-rows-json output is not valid JSON (got: $(printf '%s' "$ROWS_OUT" | head -1))"
fi

# --- Scenario 3: per-issue row schema (--emit-rows-json) ---
inc_scenario "Scenario 3: per-issue rows (loc, path, ceremony, tokens, over-served)"

ROWS3="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-rows-json 2>/dev/null)"

# Exactly 4 eligible issue rows (102→202, 302→402, 103→203, 104→204; #901 excluded).
N3="$(printf '%s' "$ROWS3" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$N3" = "4" ]; then
  pass_msg "emits exactly 4 eligible issue rows"
else
  fail_msg "expected 4 eligible rows, got $N3"
fi

# row helper: fetch a field for a given issue number via jq.
row_field() {
  local issue="$1" field="$2"
  printf '%s' "$ROWS3" | jq -r --argjson n "$issue" --arg f "$field" \
    '.[] | select(.issue == $n) | .[$f] | tostring' 2>/dev/null
}

assert_rf() {
  local issue="$1" field="$2" expected="$3"
  local actual; actual="$(row_field "$issue" "$field")"
  if [ "$actual" = "$expected" ]; then
    pass_msg "issue $issue .$field == $expected"
  else
    fail_msg "issue $issue .$field expected=$expected actual=$actual"
  fi
}

# Issue 202 (PATH B, loc 160, full ceremony, has capture → tokens>0, not over-served).
assert_rf 202 loc 160
assert_rf 202 path B
assert_rf 202 ceremony 1
assert_rf 202 over_served 0
if [ "$(printf '%s' "$ROWS3" | jq -r '.[] | select(.issue==202) | (.tokens_total | type=="number" and . > 0)' 2>/dev/null)" = "true" ]; then
  pass_msg "issue 202 .tokens_total is a number > 0"
else
  fail_msg "issue 202 .tokens_total should be a positive number"
fi

# Issue 402 (PATH B, loc 8, full ceremony, tiny diff → over-served). The operator's case.
assert_rf 402 loc 8
assert_rf 402 ceremony 1
assert_rf 402 over_served 1
if [ "$(printf '%s' "$ROWS3" | jq -r '.[] | select(.issue==402) | (.duration_ms | type=="number")' 2>/dev/null)" = "true" ]; then
  pass_msg "issue 402 .duration_ms is a number"
else
  fail_msg "issue 402 .duration_ms should be a number"
fi

# Issue 204 (PATH D quick-fix, no plan/eval comments → ceremony 0 → not over-served
# even though loc ≤ 20; AND no capture records → tokens_total null).
assert_rf 204 ceremony 0
assert_rf 204 over_served 0
if [ "$(printf '%s' "$ROWS3" | jq -r '.[] | select(.issue==204) | (.tokens_total == null)' 2>/dev/null)" = "true" ]; then
  pass_msg "issue 204 (no capture records) .tokens_total == null"
else
  fail_msg "issue 204 .tokens_total should be null (no capture records)"
fi

# --- Scenario 4: human table render (banner, per-PATH/per-stage, over-served, --) ---
inc_scenario "Scenario 4: rendered tables + over-served outliers"

TABLE4="$(bash "$HELPER" --fixture "$FIXTURE_DIR" 2>/dev/null)"

if printf '%s' "$TABLE4" | grep -q 'COST/LATENCY REPORT'; then
  pass_msg "banner present"
else
  fail_msg "banner missing"
fi

if printf '%s' "$TABLE4" | grep -q 'PATH | N'; then
  pass_msg "per-PATH aggregate header present"
else
  fail_msg "per-PATH aggregate header missing"
fi

if printf '%s' "$TABLE4" | grep -q 'STAGE | N'; then
  pass_msg "per-stage aggregate header present"
else
  fail_msg "per-stage aggregate header missing"
fi

if printf '%s' "$TABLE4" | grep -q 'issue #402' \
   && printf '%s' "$TABLE4" | grep -qF "should've been TDD/hotfix"; then
  pass_msg "over-served section flags issue #402 with literal 'should've been TDD/hotfix'"
else
  fail_msg "over-served section missing issue #402 / flag string"
fi

# Per-stage 'classify' row has zero capture records in the fixture → '--'.
CLASSIFY_ROW="$(printf '%s\n' "$TABLE4" | grep -E '^classify[[:space:]]*\|' | head -1)"
case "$CLASSIFY_ROW" in
  *--*) pass_msg "per-stage classify row renders '--' (no capture records)" ;;
  *) fail_msg "per-stage classify row missing '--' (got: $CLASSIFY_ROW)" ;;
esac

# --- Scenario 5: --over-served-loc is tunable ---
inc_scenario "Scenario 5: --over-served-loc 4 reclassifies issue 402 out"

TABLE5="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --over-served-loc 4 2>/dev/null)"
if printf '%s' "$TABLE5" | grep -qE "issue #402.*should've been"; then
  fail_msg "issue 402 should NOT be over-served when threshold=4 (loc 8 > 4)"
else
  pass_msg "issue 402 reclassified out of over-served list at threshold 4"
fi

# --- Scenario 6: empty capture → all tokens '--', still exits 0 ---
inc_scenario "Scenario 6: empty capture.jsonl degrades to '--'"

TMP6="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP6/" 2>/dev/null
: > "$TMP6/capture.jsonl"   # truncate to empty

TABLE6="$(bash "$HELPER" --fixture "$TMP6" 2>/dev/null)"
RC6=$?
if [ "$RC6" -eq 0 ]; then
  pass_msg "empty-capture run exits 0"
else
  fail_msg "empty-capture run exited non-zero (rc=$RC6)"
fi

ROWS6="$(bash "$HELPER" --fixture "$TMP6" --emit-rows-json 2>/dev/null)"
if [ "$(printf '%s' "$ROWS6" | jq -r 'all(.[]; .tokens_total == null)' 2>/dev/null)" = "true" ]; then
  pass_msg "every per-issue tokens_total is null with empty capture"
else
  fail_msg "expected all tokens_total null with empty capture"
fi
rm -rf "$TMP6"

# --- Scenario 7: --dry-run lists eligible PRs only + fixture README ---
inc_scenario "Scenario 7: --dry-run + fixture README"

DRY7="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --dry-run 2>/dev/null)"
DRY7_RC=$?
if [ "$DRY7_RC" -eq 0 ]; then
  pass_msg "--dry-run exits 0"
else
  fail_msg "--dry-run exit=$DRY7_RC"
fi

# One 'would-fetch: PR #<N>' line per eligible (non-release) PR; #901 excluded.
DRY7_COUNT="$(printf '%s\n' "$DRY7" | grep -cE '^would-fetch: PR #[0-9]+')"
if [ "$DRY7_COUNT" = "4" ]; then
  pass_msg "--dry-run prints one would-fetch line per eligible PR (n=4)"
else
  fail_msg "expected 4 would-fetch lines, got $DRY7_COUNT"
fi

# Release PR #901 must NOT appear in the dry-run list.
if printf '%s' "$DRY7" | grep -qE '^would-fetch: PR #901$'; then
  fail_msg "release PR #901 leaked into --dry-run output"
else
  pass_msg "release PR #901 excluded from --dry-run output"
fi

# --dry-run does NOT render the table.
if printf '%s' "$DRY7" | grep -q 'COST/LATENCY REPORT'; then
  fail_msg "--dry-run should not render the report banner/table"
else
  pass_msg "--dry-run does not render the table"
fi

# Fixture README documents the fixture files + capture schema.
README7="$FIXTURE_DIR/README.md"
if [ -f "$README7" ]; then
  pass_msg "fixture README.md exists"
else
  fail_msg "fixture README.md missing at $README7"
fi
for token in capture.jsonl prs.json issue- pr-; do
  if [ -f "$README7" ] && grep -qF "$token" "$README7"; then
    pass_msg "README documents '$token'"
  else
    fail_msg "README does not mention '$token'"
  fi
done

# --- Scenario 8: a malformed capture line is tolerated (valid records still sum) ---
# An append-only log read mid-write can have a torn line; one bad line must NOT
# silently zero the whole report.
inc_scenario "Scenario 8: malformed capture line tolerated"

TMP8="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP8/" 2>/dev/null
{ echo 'this is not json'; cat "$FIXTURE_DIR/capture.jsonl"; } > "$TMP8/capture.jsonl"

ROWS8="$(bash "$HELPER" --fixture "$TMP8" --emit-rows-json 2>/dev/null)"
RC8=$?
if [ "$RC8" -eq 0 ]; then
  pass_msg "run with a malformed capture line exits 0"
else
  fail_msg "run with a malformed capture line exited non-zero (rc=$RC8)"
fi

# 202's deduped total is 125499 (record_key K202PLAN last-write-wins → 99999,
# not 99999+7000); the malformed line must not perturb the valid-record sum.
TT8="$(printf '%s' "$ROWS8" | jq -r '.[] | select(.issue==202) | .tokens_total' 2>/dev/null)"
if [ "$TT8" = "125499" ]; then
  pass_msg "valid capture records still summed (deduped) despite one malformed line (202=125499)"
else
  fail_msg "expected issue 202 tokens_total=125499 with a malformed line present, got $TT8"
fi
rm -rf "$TMP8"

# --- Scenario 9: orchestrator stage row renders (#662) ---
inc_scenario "Scenario 9: orchestrator stage row renders in per-stage table"

TMP9="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP9/" 2>/dev/null
# Append an orchestrator capture record in the honest post-#667 shape: issue:""
# (session-scoped, NOT PR-linked), session_id present, duration_ms null. Pre-fix
# records carried a non-null duration_ms and are now dropped (#678 Scenario 11),
# so this fixture is reconciled to the null-duration shape it must survive under.
{ cat "$FIXTURE_DIR/capture.jsonl";
  echo '{"schema_version":1,"issue":"","stage":"orchestrator","session_id":"sess-9","agent_kind":"main","agent_type":"orchestrator","tokens":{"input":500,"output":300,"cache_read":1000,"cache_creation":0,"total":1800},"duration_ms":null}';
} > "$TMP9/capture.jsonl"

TABLE9="$(bash "$HELPER" --fixture "$TMP9" 2>/dev/null)"
if printf '%s\n' "$TABLE9" | grep -qE '^orchestrator[[:space:]]*\|'; then
  pass_msg "per-stage table renders an 'orchestrator' row"
else
  fail_msg "per-stage table missing 'orchestrator' row"
fi
rm -rf "$TMP9"

# --- Scenario 10: orchestrator issue:"" records render a NON-ZERO stage row (#669) ---
# Orchestrator records are session-scoped (issue:"" — no PR link). The per-stage
# join must NOT gate them by the in-window PR-issue filter, else the orchestrator
# row always renders "orchestrator | 0 | -- | --" even though records exist.
inc_scenario "Scenario 10: orchestrator issue:\"\" records render a non-zero stage row"

TMP10="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP10/" 2>/dev/null
# One orchestrator record with issue:"" (session-scoped, NOT PR-linked) in the
# honest post-#667 shape (session_id present, duration_ms null — pre-fix non-null
# records are now dropped per #678 Scenario 11). A single record is its own median,
# so tokens median=1800 unambiguously.
{ cat "$FIXTURE_DIR/capture.jsonl";
  echo '{"schema_version":1,"issue":"","stage":"orchestrator","session_id":"sess-10","agent_kind":"main","agent_type":"orchestrator","tokens":{"input":500,"output":300,"cache_read":1000,"cache_creation":0,"total":1800},"duration_ms":null}';
} > "$TMP10/capture.jsonl"

TABLE10="$(bash "$HELPER" --fixture "$TMP10" 2>/dev/null)"
ORCH_ROW10="$(printf '%s\n' "$TABLE10" | grep -E '^orchestrator[[:space:]]*\|' | head -1)"

# N column must be >= 1 (record was NOT filtered out).
ORCH_N10="$(printf '%s' "$ORCH_ROW10" | awk -F'|' '{gsub(/ /,"",$2); print $2}')"
if [ "${ORCH_N10:-0}" -ge 1 ] 2>/dev/null; then
  pass_msg "orchestrator row N>=1 for issue:\"\" records (N=$ORCH_N10)"
else
  fail_msg "orchestrator row N should be >=1 for issue:\"\" records (got row: $ORCH_ROW10)"
fi

# Median tokens cell must be the real number 1800, NOT '--'.
case "$ORCH_ROW10" in
  *1800*) pass_msg "orchestrator row renders real median tokens (1800), not '--'" ;;
  *) fail_msg "orchestrator row should render 1800 tokens, not '--' (got: $ORCH_ROW10)" ;;
esac
rm -rf "$TMP10"

# --- Scenario 11: orchestrator pre-fix records (non-null duration_ms) excluded (#678) ---
# Pre-#667 orchestrator records carry a non-null duration_ms (≈137M ms) and a
# cache_read-inflated tokens.total (≈257M), which the report summed into a
# grand all-time orchestrator row. Post-#667 orchestrator duration_ms is ALWAYS
# null. The report must drop the non-null-duration (pre-fix garbage) records.
inc_scenario "Scenario 11: orchestrator pre-fix records (non-null duration_ms) excluded"

TMP11="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP11/" 2>/dev/null
{ cat "$FIXTURE_DIR/capture.jsonl";
  # PRE-FIX garbage: non-null duration_ms + inflated total → must be DROPPED.
  echo '{"schema_version":1,"issue":"","stage":"orchestrator","session_id":"sess-old","agent_kind":"main","agent_type":"orchestrator","tokens":{"input":1,"output":1,"cache_read":257648472,"cache_creation":0,"total":257648474},"duration_ms":137345028}';
  # POST-FIX honest record: null duration_ms → must be KEPT.
  echo '{"schema_version":1,"issue":"","stage":"orchestrator","session_id":"sess-new","agent_kind":"main","agent_type":"orchestrator","tokens":{"input":500,"output":300,"cache_read":1000,"cache_creation":0,"total":1800},"duration_ms":null}';
} > "$TMP11/capture.jsonl"

TABLE11="$(bash "$HELPER" --fixture "$TMP11" 2>/dev/null)"
ORCH_ROW11="$(printf '%s\n' "$TABLE11" | grep -E '^orchestrator[[:space:]]*\|' | head -1)"

# The grand garbage total must NOT appear anywhere in the orchestrator row.
case "$ORCH_ROW11" in
  *257648474*) fail_msg "orchestrator row leaked pre-fix tokens.total 257648474 (got: $ORCH_ROW11)" ;;
  *) pass_msg "orchestrator row excludes pre-fix tokens.total (257648474 absent)" ;;
esac
# The pre-fix duration must NOT leak into the slow-stages / any rendered cell.
case "$TABLE11" in
  *137345028*) fail_msg "report leaked pre-fix duration_ms 137345028" ;;
  *) pass_msg "report excludes pre-fix duration_ms (137345028 absent)" ;;
esac
# The post-fix record must still be present (1800 tokens).
case "$ORCH_ROW11" in
  *1800*) pass_msg "orchestrator row keeps post-fix record (1800 tokens)" ;;
  *) fail_msg "orchestrator row should keep post-fix 1800-token record (got: $ORCH_ROW11)" ;;
esac
rm -rf "$TMP11"

# --- Scenario 12: orchestrator records grouped by session_id, not collapsed to N=1 (#678) ---
# Orchestrator issue is the constant "" so group_by([issue, stage]) is degenerate
# (always N=1, and the "median" cell is the grand all-time sum). Orchestrator
# records must group by session_id so the row reflects a per-session distribution.
inc_scenario "Scenario 12: orchestrator records grouped by session_id (per-session N)"

TMP12="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP12/" 2>/dev/null
# THREE post-fix orchestrator records (duration_ms:null) across TWO sessions:
#   sess-A: snapshots 1000 + 3000   sess-B: 2000
# The (session_id,issue,stage) max-total dedup (#721) collapses sess-A's two
# cumulative snapshots to its FINAL cumulative (max-total 3000), so:
#   sess-A → 3000   sess-B → 2000
# → N must be 2 (two session groups); median of per-session totals (3000, 2000) = 2500.
#   NOT N=1 and NOT the grand sum 6000.
{ cat "$FIXTURE_DIR/capture.jsonl";
  echo '{"schema_version":1,"issue":"","stage":"orchestrator","session_id":"sess-A","agent_kind":"main","agent_type":"orchestrator","tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0,"total":1000},"duration_ms":null}';
  echo '{"schema_version":1,"issue":"","stage":"orchestrator","session_id":"sess-A","agent_kind":"main","agent_type":"orchestrator","tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0,"total":3000},"duration_ms":null}';
  echo '{"schema_version":1,"issue":"","stage":"orchestrator","session_id":"sess-B","agent_kind":"main","agent_type":"orchestrator","tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0,"total":2000},"duration_ms":null}';
} > "$TMP12/capture.jsonl"

TABLE12="$(bash "$HELPER" --fixture "$TMP12" 2>/dev/null)"
ORCH_ROW12="$(printf '%s\n' "$TABLE12" | grep -E '^orchestrator[[:space:]]*\|' | head -1)"

ORCH_N12="$(printf '%s' "$ORCH_ROW12" | awk -F'|' '{gsub(/ /,"",$2); print $2}')"
if [ "${ORCH_N12:-0}" = "2" ]; then
  pass_msg "orchestrator row N==2 (two session groups, not collapsed to 1)"
else
  fail_msg "orchestrator row N should be 2 (per-session), got N=$ORCH_N12 (row: $ORCH_ROW12)"
fi

# Median tokens cell == median of per-session max-totals (3000, 2000) == 2500.
ORCH_TOK12="$(printf '%s' "$ORCH_ROW12" | awk -F'|' '{gsub(/ /,"",$3); print $3}')"
if [ "$ORCH_TOK12" = "2500" ]; then
  pass_msg "orchestrator median tokens == 2500 (median of per-session max-totals, #721)"
else
  fail_msg "orchestrator median tokens should be 2500 (median of per-session max-totals), got $ORCH_TOK12 (row: $ORCH_ROW12)"
fi

# Must NOT be the grand all-time sum.
case "$ORCH_ROW12" in
  *6000*) fail_msg "orchestrator row leaked grand all-time sum 6000 (row: $ORCH_ROW12)" ;;
  *) pass_msg "orchestrator row does not render grand all-time sum 6000" ;;
esac
rm -rf "$TMP12"

# --- Scenario 13: orchestrator slow-stage label + cache_read annotation (#678) ---
# (a) The TOP-N SLOWEST STAGES list ranks by duration_ms; orchestrator dur is
#     null (post-#667), and its STAGE_TSV col1 is now a session_id, so the old
#     `issue #<session>` literal is misleading. It must not appear.
# (b) The per-stage orchestrator row must flag the cache_read asymmetry (#668):
#     orchestrator tokens.total EXCLUDES cache_read while inline totals include
#     it, so the two are not directly comparable.
inc_scenario "Scenario 13: orchestrator slow-stage label + cache_read annotation"

TMP13="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP13/" 2>/dev/null
{ cat "$FIXTURE_DIR/capture.jsonl";
  echo '{"schema_version":1,"issue":"","stage":"orchestrator","session_id":"sess-13","agent_kind":"main","agent_type":"orchestrator","tokens":{"input":500,"output":300,"cache_read":1000,"cache_creation":0,"total":1800},"duration_ms":null}';
} > "$TMP13/capture.jsonl"

# Render with a high --top-n so the orchestrator group is NOT truncated out of
# the slowest-stages list by head -N — forces the relabel/omit path to be
# exercised rather than passing by coincidence of fixture size.
TABLE13="$(bash "$HELPER" --fixture "$TMP13" --top-n 50 2>/dev/null)"

# (a) No misleading `issue #sess-13` literal anywhere in the slowest-stages list.
case "$TABLE13" in
  *"issue #sess-13"*) fail_msg "slow-stages list printed misleading 'issue #sess-13' for an orchestrator session key" ;;
  *) pass_msg "slow-stages list does not print 'issue #<session>' for orchestrator" ;;
esac

# (b) The orchestrator per-stage row carries a cache_read-asymmetry annotation.
ORCH_ROW13="$(printf '%s\n' "$TABLE13" | grep -E '^orchestrator[[:space:]]*\|' | head -1)"
case "$ORCH_ROW13" in
  *cache_read*) pass_msg "orchestrator row annotates cache_read asymmetry (got: $ORCH_ROW13)" ;;
  *) fail_msg "orchestrator row missing cache_read-asymmetry annotation (got: $ORCH_ROW13)" ;;
esac
rm -rf "$TMP13"

# --- Scenario 14: record_key collisions are deduped (last-write-wins) (#698) ---
# A capture record's record_key is a LOGICAL idempotency key: the same key may
# recur across appends with revised token totals (same logical agent finish).
# Any consumer that SUMS token/duration fields must first dedup on record_key
# (group_by(.record_key) | last), else a key that legitimately recurs is
# double-counted. The shared fixture carries TWO records for issue 202 / stage
# 'plan' sharing record_key "K202PLAN" with divergent tokens.total (7000, 99999);
# last-write-wins keeps only 99999.
inc_scenario "Scenario 14: record_key collisions deduped (last-write-wins)"

# Per-issue path (--emit-rows-json). Deduped 202 total = 99999 (plan, last wins)
# + 17000 (execute) + 8500 (pr-eval) = 125499. The naive (un-deduped) sum would
# also add the shadowed 7000 → 132499; assert the EXACT deduped integer.
ROWS14="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-rows-json 2>/dev/null)"
TT14="$(printf '%s' "$ROWS14" | jq -r '.[] | select(.issue==202) | .tokens_total' 2>/dev/null)"
if [ "$TT14" = "125499" ]; then
  pass_msg "per-issue 202 tokens_total deduped on record_key (125499, last-write-wins)"
else
  fail_msg "per-issue 202 tokens_total should be 125499 (deduped), got $TT14"
fi

# Per-stage path (STAGE_TSV → per-stage table). The 'plan' stage row's median is
# over per-(issue,stage) plan sums: {202: 99999 (deduped), 402: 5700} → median
# (5700+99999)/2 = 52849.5. The naive sum would make 202's plan group 106999
# (7000+99999) → median 56349.5. Assert the deduped median, reject the naive one.
TABLE14="$(bash "$HELPER" --fixture "$FIXTURE_DIR" 2>/dev/null)"
PLAN_ROW14="$(printf '%s\n' "$TABLE14" | grep -E '^plan[[:space:]]*\|' | head -1)"
case "$PLAN_ROW14" in
  *52849.5*) pass_msg "per-stage 'plan' median reflects deduped 202 sum (52849.5)" ;;
  *) fail_msg "per-stage 'plan' median should be 52849.5 (deduped), got: $PLAN_ROW14" ;;
esac
case "$PLAN_ROW14" in
  *56349.5*) fail_msg "per-stage 'plan' median leaked naive un-deduped 202 sum (56349.5): $PLAN_ROW14" ;;
  *) pass_msg "per-stage 'plan' median excludes naive un-deduped 202 sum (56349.5 absent)" ;;
esac

# --- Scenario 15: (session,issue,stage) max-total dedup + multi-session re-run preserved (#721) ---
# A SECOND dedup pass (after the record_key pass) collapses records sharing the
# same (session_id, issue, stage) to the one with MAX tokens.total — folding
# retroactive-inline lower-bounds, duplicate captures, and N cumulative
# orchestrator snapshots of one session down to the final cumulative figure.
# DISTINCT session_ids for the same (issue,stage) are a genuine multi-session
# re-run and MUST be preserved.
inc_scenario "Scenario 15: (session,issue,stage) max-total dedup + multi-session re-run preserved"

TMP15="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP15/" 2>/dev/null
# Add an extra eligible feature PR #105 → fresh issue #205 (not 202/402/203/204/999).
printf '%s\n' '[
  {"number":102,"title":"feat(api): add endpoint","additions":120,"deletions":40,"body":"Closes #202","mergedAt":"2026-05-11T10:00:00Z","labels":[]},
  {"number":302,"title":"feat: tiny tweak","additions":5,"deletions":3,"body":"Closes #402","mergedAt":"2026-05-14T10:00:00Z","labels":[]},
  {"number":103,"title":"refactor(core): split modules","additions":500,"deletions":300,"body":"Closes #203","mergedAt":"2026-05-12T10:00:00Z","labels":[{"name":"multi-task"}]},
  {"number":104,"title":"fix(util): tiny bug","additions":2,"deletions":1,"body":"Closes #204","mergedAt":"2026-05-13T10:00:00Z","labels":[{"name":"quick-fix"}]},
  {"number":105,"title":"feat: fresh issue for dedup test","additions":300,"deletions":100,"body":"Closes #205","mergedAt":"2026-05-13T12:00:00Z","labels":[]},
  {"number":901,"title":"chore(main): release 0.99.0","additions":50,"deletions":10,"body":"","mergedAt":"2026-05-15T10:00:00Z","labels":[{"name":"autorelease: tagged"}]}
]' > "$TMP15/prs.json"
printf '%s\n' '{"number":105,"additions":300,"deletions":100,"comments":[]}' > "$TMP15/pr-105.json"
printf '%s\n' '{"number":205,"labels":[],"comments":[]}' > "$TMP15/issue-205.json"
# Custom capture for issue 205:
#   (sX, 205, execute): two records, divergent tokens.total (1000, 5000), DIFFERENT
#     record_key → record_key pass keeps BOTH; new (session,issue,stage) max-total
#     pass collapses to 5000.
#   (sA, 205, plan)=100 and (sB, 205, plan)=200: same (issue,stage) but DISTINCT
#     session_ids → genuine re-run, both PRESERVED.
# Deduped per-issue 205 total = 5000 + 100 + 200 = 5300 (NOT the naive 6300).
{
  echo '{"schema_version":1,"issue":"205","stage":"execute","session_id":"sX","agent_kind":"sub","record_key":"K205A","tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0,"total":1000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"205","stage":"execute","session_id":"sX","agent_kind":"sub","record_key":"K205B","tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0,"total":5000},"duration_ms":2000}'
  echo '{"schema_version":1,"issue":"205","stage":"plan","session_id":"sA","agent_kind":"sub","record_key":"K205PA","tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0,"total":100},"duration_ms":500}'
  echo '{"schema_version":1,"issue":"205","stage":"plan","session_id":"sB","agent_kind":"sub","record_key":"K205PB","tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0,"total":200},"duration_ms":600}'
} > "$TMP15/capture.jsonl"

ROWS15="$(bash "$HELPER" --fixture "$TMP15" --emit-rows-json 2>/dev/null)"
TT15="$(printf '%s' "$ROWS15" | jq -r '.[] | select(.issue==205) | .tokens_total' 2>/dev/null)"
if [ "$TT15" = "5300" ]; then
  pass_msg "issue 205 tokens_total deduped on (session,issue,stage) max-total (5300), multi-session plan preserved"
else
  fail_msg "issue 205 tokens_total should be 5300 (5000 max-total + 100 + 200), got $TT15"
fi
# The naive (no session-stage dedup) sum would keep the shadowed 1000 → 6300.
if [ "$TT15" = "6300" ]; then
  fail_msg "issue 205 tokens_total leaked shadowed lower-bound record (naive 6300)"
else
  pass_msg "issue 205 tokens_total excludes shadowed lower-bound (naive 6300 rejected)"
fi
rm -rf "$TMP15"

# --- Scenario 16: per-model pricing + unpriced (empty-model) count (#721) ---
# A config-driven pricing helper prices each capture record from per-model rate
# env vars (PIPELINE_PRICE_<MODEL>_{INPUT,OUTPUT,CACHE_CREATION,CACHE_READ}),
# falling back to the Opus default list price per bucket (per 1M tokens):
#   input 15, output 75, cache_creation 18.75, cache_read 1.50.
# Records with model=="" (issue #699 INLINE records) are UNPRICED: excluded from
# the $ total and COUNTED so coverage health is visible. Surfaced via
# --emit-pricing-json → {priced_cost_usd, unpriced_count}.
#
# Golden (Opus defaults, no env override) for the ONE priced record below:
#   input          2,000,000 → 2 * 15      = $30.00
#   output         1,000,000 → 1 * 75      = $75.00
#   cache_creation 4,000,000 → 4 * 18.75   = $75.00
#   cache_read     8,000,000 → 8 * 1.50    = $12.00
#                                    TOTAL = $192.00
inc_scenario "Scenario 16: per-model pricing + unpriced empty-model count"

TMP16="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP16/" 2>/dev/null
# Two eligible feature PRs → fresh issues 206 (priced opus record) and 207 (unpriced).
printf '%s\n' '[
  {"number":106,"title":"feat: priced record issue","additions":300,"deletions":100,"body":"Closes #206","mergedAt":"2026-05-13T12:00:00Z","labels":[]},
  {"number":107,"title":"feat: unpriced record issue","additions":50,"deletions":20,"body":"Closes #207","mergedAt":"2026-05-13T13:00:00Z","labels":[]}
]' > "$TMP16/prs.json"
printf '%s\n' '{"number":106,"additions":300,"deletions":100,"comments":[]}' > "$TMP16/pr-106.json"
printf '%s\n' '{"number":206,"labels":[],"comments":[]}' > "$TMP16/issue-206.json"
printf '%s\n' '{"number":107,"additions":50,"deletions":20,"comments":[]}' > "$TMP16/pr-107.json"
printf '%s\n' '{"number":207,"labels":[],"comments":[]}' > "$TMP16/issue-207.json"
{
  echo '{"schema_version":1,"issue":"206","stage":"execute","session_id":"sP","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K206","tokens":{"input":2000000,"output":1000000,"cache_read":8000000,"cache_creation":4000000,"total":15000000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"207","stage":"execute","session_id":"sU","model":"","agent_kind":"inline","record_key":"K207","tokens":{"input":500000,"output":500000,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":900}'
} > "$TMP16/capture.jsonl"

# Pricing math uses Opus defaults (no PIPELINE_PRICE_* env exported here).
PRICING16="$(env -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT \
                 -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT \
                 -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION \
                 -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ \
             bash "$HELPER" --fixture "$TMP16" --emit-pricing-json 2>/dev/null)"

if printf '%s' "$PRICING16" | jq -e . >/dev/null 2>&1; then
  pass_msg "--emit-pricing-json output parses as JSON"
else
  fail_msg "--emit-pricing-json output is not valid JSON (got: $(printf '%s' "$PRICING16" | head -1))"
fi

COST16="$(printf '%s' "$PRICING16" | jq -r '.priced_cost_usd' 2>/dev/null)"
if [ "$COST16" = "192.00" ] || [ "$COST16" = "192" ] || [ "$COST16" = "192.0" ]; then
  pass_msg "priced_cost_usd == 192.00 (Opus default rates, golden arithmetic)"
else
  fail_msg "priced_cost_usd should be 192.00 (30+75+75+12), got $COST16"
fi

UNPRICED16="$(printf '%s' "$PRICING16" | jq -r '.unpriced_count' 2>/dev/null)"
if [ "$UNPRICED16" = "1" ]; then
  pass_msg "unpriced_count == 1 (empty-model record counted, #699)"
else
  fail_msg "unpriced_count should be 1 (one model:\"\" record), got $UNPRICED16"
fi

# The unpriced record's 1,000,000 input+output tokens (would be $45 at Opus
# rates) must NOT leak into the priced total — total stays 192, not 237.
case "$COST16" in
  237*) fail_msg "priced_cost_usd leaked the unpriced empty-model record (237)" ;;
  *) pass_msg "priced_cost_usd excludes the unpriced empty-model record (237 rejected)" ;;
esac
rm -rf "$TMP16"

# --- Scenario 17: --tokenomics bucket table (token-share vs cost-share) (#721) ---
# Under --tokenomics, emit a per-bucket (input/output/cache_creation/cache_read)
# table with: total tokens, priced $ (Opus default rates over priced records),
# and %-of-cost. Headline finding: token-share != cost-share.
# Fixture: ONE priced opus record where:
#   output     1,000,000  → $75.00  (token-share 9.09%, cost-share 83.33%)
#   cache_read 10,000,000 → $15.00  (token-share 90.9%, cost-share 16.67%)
#   input 0, cache_creation 0
# Total tokens = 11,000,000; total cost = $90.00.
# Assert: output cost% > output token%  AND  cache_read cost% < cache_read token%.
# Also assert DEFAULT output (no --tokenomics) is byte-unchanged (no bucket table).
inc_scenario "Scenario 17: --tokenomics bucket table (token-share vs cost-share)"

TMP17="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP17/" 2>/dev/null
printf '%s\n' '[
  {"number":117,"title":"feat: bucket table issue","additions":300,"deletions":100,"body":"Closes #217","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP17/prs.json"
printf '%s\n' '{"number":117,"additions":300,"deletions":100,"comments":[]}' > "$TMP17/pr-117.json"
printf '%s\n' '{"number":217,"labels":[],"comments":[]}' > "$TMP17/issue-217.json"
{
  echo '{"schema_version":1,"issue":"217","stage":"execute","session_id":"s17","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K217","tokens":{"input":0,"output":1000000,"cache_read":10000000,"cache_creation":0,"total":11000000},"duration_ms":1000}'
} > "$TMP17/capture.jsonl"

# Default (no --tokenomics): NO bucket table.
DEF17="$(bash "$HELPER" --fixture "$TMP17" 2>/dev/null)"
if printf '%s' "$DEF17" | grep -qi 'BUCKET'; then
  fail_msg "default output (no --tokenomics) leaked a BUCKET table"
else
  pass_msg "default output has no bucket table (gated behind --tokenomics)"
fi

TOK17="$(bash "$HELPER" --fixture "$TMP17" --tokenomics 2>/dev/null)"

# Bucket table header present under --tokenomics.
if printf '%s' "$TOK17" | grep -qiE 'BUCKET.*cost'; then
  pass_msg "--tokenomics renders a per-bucket cost table"
else
  fail_msg "--tokenomics missing per-bucket cost table header"
fi

# Parse the output + cache_read rows: cols are "bucket | tokens | $ | cost%" with
# token% appended. We assert via the rendered cost% and token% values.
OUT_ROW17="$(printf '%s\n' "$TOK17" | grep -E '^output[[:space:]]*\|' | head -1)"
CR_ROW17="$(printf '%s\n' "$TOK17" | grep -E '^cache_read[[:space:]]*\|' | head -1)"

# output: token% ~9.1, cost% ~83.3 → cost% > token%.
OUT_TOKPCT="$(printf '%s' "$OUT_ROW17" | awk -F'|' '{gsub(/[ %]/,"",$5); print $5+0}')"
OUT_COSTPCT="$(printf '%s' "$OUT_ROW17" | awk -F'|' '{gsub(/[ %]/,"",$4); print $4+0}')"
if awk -v c="$OUT_COSTPCT" -v t="$OUT_TOKPCT" 'BEGIN{exit !(c>t)}'; then
  pass_msg "output bucket cost% ($OUT_COSTPCT) > token% ($OUT_TOKPCT)"
else
  fail_msg "output bucket cost% should exceed token% (cost%=$OUT_COSTPCT token%=$OUT_TOKPCT row=$OUT_ROW17)"
fi

# cache_read: token% ~90.9, cost% ~16.7 → cost% < token%.
CR_TOKPCT="$(printf '%s' "$CR_ROW17" | awk -F'|' '{gsub(/[ %]/,"",$5); print $5+0}')"
CR_COSTPCT="$(printf '%s' "$CR_ROW17" | awk -F'|' '{gsub(/[ %]/,"",$4); print $4+0}')"
if awk -v c="$CR_COSTPCT" -v t="$CR_TOKPCT" 'BEGIN{exit !(c<t)}'; then
  pass_msg "cache_read bucket cost% ($CR_COSTPCT) < token% ($CR_TOKPCT)"
else
  fail_msg "cache_read bucket cost% should be below token% (cost%=$CR_COSTPCT token%=$CR_TOKPCT row=$CR_ROW17)"
fi

# Sanity: output bucket $ == 75.00 (golden), cache_read $ == 15.00 (golden).
OUT_USD17="$(printf '%s' "$OUT_ROW17" | awk -F'|' '{gsub(/[ $]/,"",$3); print $3}')"
CR_USD17="$(printf '%s' "$CR_ROW17" | awk -F'|' '{gsub(/[ $]/,"",$3); print $3}')"
if [ "$OUT_USD17" = "75.00" ]; then
  pass_msg "output bucket priced \$ == 75.00 (golden)"
else
  fail_msg "output bucket \$ should be 75.00, got $OUT_USD17 (row=$OUT_ROW17)"
fi
if [ "$CR_USD17" = "15.00" ]; then
  pass_msg "cache_read bucket priced \$ == 15.00 (golden)"
else
  fail_msg "cache_read bucket \$ should be 15.00, got $CR_USD17 (row=$CR_ROW17)"
fi
rm -rf "$TMP17"

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
