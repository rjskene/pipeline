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

# --- Scenario 18: --tokenomics per-stage cost table (size nets out cache_read) (#721) ---
# Per-stage table with priced $ + cost share. The TOKEN column is a SIZE view:
# tokens = input+output+cache_creation (EXCLUDING cache_read), so execute does
# not read as ~90% cache; but the $ column uses ALL FOUR buckets.
# Fixture: one 'execute' priced opus record with a huge cache_read:
#   input          1,000,000   → $15.00
#   cache_read   100,000,000   → $150.00
#   output 0, cache_creation 0
#   size tokens = 1,000,000 (cache_read EXCLUDED); $ = 165.00 (cache_read INCLUDED).
inc_scenario "Scenario 18: --tokenomics per-stage cost table (size nets out cache_read)"

TMP18="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP18/" 2>/dev/null
printf '%s\n' '[
  {"number":118,"title":"feat: stage cost table issue","additions":300,"deletions":100,"body":"Closes #218","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP18/prs.json"
printf '%s\n' '{"number":118,"additions":300,"deletions":100,"comments":[]}' > "$TMP18/pr-118.json"
printf '%s\n' '{"number":218,"labels":[],"comments":[]}' > "$TMP18/issue-218.json"
{
  echo '{"schema_version":1,"issue":"218","stage":"execute","session_id":"s18","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K218","tokens":{"input":1000000,"output":0,"cache_read":100000000,"cache_creation":0,"total":101000000},"duration_ms":1000}'
} > "$TMP18/capture.jsonl"

# Default (no --tokenomics): NO per-stage COST table (the legacy 'STAGE | N' table
# is unaffected; this is a new header).
DEF18="$(bash "$HELPER" --fixture "$TMP18" 2>/dev/null)"
if printf '%s' "$DEF18" | grep -qiE 'STAGE COST'; then
  fail_msg "default output leaked a STAGE COST table"
else
  pass_msg "default output has no per-stage cost table (gated behind --tokenomics)"
fi

TOK18="$(bash "$HELPER" --fixture "$TMP18" --tokenomics 2>/dev/null)"
if printf '%s' "$TOK18" | grep -qiE 'STAGE COST'; then
  pass_msg "--tokenomics renders a per-stage cost table"
else
  fail_msg "--tokenomics missing per-stage cost table header"
fi

# Locate the per-stage COST table's execute row (after the STAGE COST header to
# avoid colliding with the legacy 'execute' median-token row).
STAGECOST_BLOCK18="$(printf '%s\n' "$TOK18" | awk '/STAGE COST/{f=1} f')"
EXEC_ROW18="$(printf '%s\n' "$STAGECOST_BLOCK18" | grep -E '^execute[[:space:]]*\|' | head -1)"

# Size-view tokens column == 1000000 (cache_read EXCLUDED), NOT 101000000.
EXEC_SIZE18="$(printf '%s' "$EXEC_ROW18" | awk -F'|' '{gsub(/[ ]/,"",$2); print $2}')"
if [ "$EXEC_SIZE18" = "1000000" ]; then
  pass_msg "execute size-view tokens == 1000000 (cache_read excluded)"
else
  fail_msg "execute size-view tokens should be 1000000 (nets out cache_read), got $EXEC_SIZE18 (row=$EXEC_ROW18)"
fi
case "$EXEC_ROW18" in
  *101000000*) fail_msg "execute size-view tokens leaked cache_read (101000000): $EXEC_ROW18" ;;
  *) pass_msg "execute size-view tokens excludes cache_read total (101000000 absent)" ;;
esac

# $ column INCLUDES cache_read cost → 165.00 (15 input + 150 cache_read).
EXEC_USD18="$(printf '%s' "$EXEC_ROW18" | awk -F'|' '{gsub(/[ $]/,"",$3); print $3}')"
if [ "$EXEC_USD18" = "165.00" ]; then
  pass_msg "execute \$ == 165.00 (cache_read cost INCLUDED)"
else
  fail_msg "execute \$ should be 165.00 (15 + 150 cache_read), got $EXEC_USD18 (row=$EXEC_ROW18)"
fi
rm -rf "$TMP18"

# --- Scenario 19: --tokenomics structure table + stage×structure cross-tab (#721, #789) ---
# Structure dimension: spawn = agent_kind=="headless"; in-session = agent_kind!=
# "headless" (inline + main/orchestrator). Header (revised #789):
#   STRUCTURE | N | input | output | cache_creation | cache_read | $ | cost%
# Token-bucket columns + N source from CAPTURE_JSON (ALL records) keyed on
# agent_kind, so the in-session (inline) row shows REAL token counts even when
# model="" (unpriced). The $/cost% columns stay PRICED-ONLY; an all-unpriced
# in-session row renders $ == '--' with an '(unpriced)' mark.
# Fixture (#789 LIVE shape):
#   headless / execute: input 2,000,000 PRICED → spawn $30.00
#   inline   / plan:    input 1,000,000 UNPRICED (model="") → in-session tokens
#                       real, but $ == '--' (unpriced)
# crosstab: execute×spawn = 30.00 ; plan×in-session = 0.00 (inline now unpriced).
inc_scenario "Scenario 19: --tokenomics structure table + stage×structure cross-tab"

TMP19="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP19/" 2>/dev/null
printf '%s\n' '[
  {"number":119,"title":"feat: structure table issue","additions":300,"deletions":100,"body":"Closes #219","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP19/prs.json"
printf '%s\n' '{"number":119,"additions":300,"deletions":100,"comments":[]}' > "$TMP19/pr-119.json"
printf '%s\n' '{"number":219,"labels":[],"comments":[]}' > "$TMP19/issue-219.json"
{
  echo '{"schema_version":1,"issue":"219","stage":"execute","session_id":"s19a","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K219A","tokens":{"input":2000000,"output":0,"cache_read":0,"cache_creation":0,"total":2000000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"219","stage":"plan","session_id":"s19b","model":"","agent_kind":"inline","record_key":"K219B","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":900}'
} > "$TMP19/capture.jsonl"

DEF19="$(bash "$HELPER" --fixture "$TMP19" 2>/dev/null)"
if printf '%s' "$DEF19" | grep -qiE 'STRUCTURE'; then
  fail_msg "default output leaked a STRUCTURE table"
else
  pass_msg "default output has no structure table (gated behind --tokenomics)"
fi

TOK19="$(bash "$HELPER" --fixture "$TMP19" --tokenomics 2>/dev/null)"
if printf '%s' "$TOK19" | grep -qiE 'STRUCTURE'; then
  pass_msg "--tokenomics renders a structure table"
else
  fail_msg "--tokenomics missing structure table header"
fi

# Structure header carries the four token-bucket columns + N.
STRUCT_HDR19="$(printf '%s\n' "$TOK19" | grep -E '^STRUCTURE[[:space:]]*\|')"
for col in input output cache_creation cache_read; do
  case "$STRUCT_HDR19" in
    *"$col"*) pass_msg "structure header carries '$col' column" ;;
    *) fail_msg "structure header missing '$col' column (got: $STRUCT_HDR19)" ;;
  esac
done

# Row shape: STRUCTURE | N | input | output | cache_creation | cache_read | $ | cost%
SPAWN_ROW19="$(printf '%s\n' "$TOK19" | grep -E '^spawn[[:space:]]*\|' | head -1)"
INSESS_ROW19="$(printf '%s\n' "$TOK19" | grep -E '^in-session[[:space:]]*\|' | head -1)"

# spawn (headless, priced): input bucket 2000000, $ == 30.00.
SPAWN_IN19="$(printf '%s' "$SPAWN_ROW19" | awk -F'|' '{gsub(/[ ]/,"",$3); print $3}')"
SPAWN_USD19="$(printf '%s' "$SPAWN_ROW19" | awk -F'|' '{gsub(/[ $]/,"",$7); print $7}')"
if [ "$SPAWN_IN19" = "2000000" ]; then pass_msg "spawn input bucket == 2000000"; else fail_msg "spawn input should be 2000000, got $SPAWN_IN19 (row=$SPAWN_ROW19)"; fi
if [ "$SPAWN_USD19" = "30.00" ]; then pass_msg "spawn structure \$ == 30.00 (headless priced)"; else fail_msg "spawn structure \$ should be 30.00, got $SPAWN_USD19 (row=$SPAWN_ROW19)"; fi

# in-session (inline UNPRICED): input bucket 1000000 (REAL, non-zero), $ == '--' / (unpriced).
INSESS_IN19="$(printf '%s' "$INSESS_ROW19" | awk -F'|' '{gsub(/[ ]/,"",$3); print $3}')"
if [ "$INSESS_IN19" = "1000000" ]; then
  pass_msg "in-session input bucket == 1000000 (unpriced inline shows REAL tokens)"
else
  fail_msg "in-session input should be 1000000 (real unpriced tokens), got $INSESS_IN19 (row=$INSESS_ROW19)"
fi
case "$INSESS_ROW19" in
  *unpriced*) pass_msg "in-session row carries an (unpriced) mark (all records model=\"\")" ;;
  *) fail_msg "in-session row should carry an (unpriced) mark (got: $INSESS_ROW19)" ;;
esac
INSESS_USD19="$(printf '%s' "$INSESS_ROW19" | awk -F'|' '{gsub(/[ $]/,"",$7); print $7}')"
case "$INSESS_USD19" in
  *--*) pass_msg "in-session \$ renders '--' (unpriced, never read as zero-token)" ;;
  *) fail_msg "in-session \$ should render '--' when all records unpriced, got '$INSESS_USD19' (row=$INSESS_ROW19)" ;;
esac

# Cross-tab: stage × structure $ matrix (PRICED-only, unchanged by #789).
XTAB_BLOCK19="$(printf '%s\n' "$TOK19" | awk '/STAGE.STRUCTURE|STAGE x STRUCTURE|CROSS-TAB|CROSSTAB/{f=1} f')"
XEXEC_ROW19="$(printf '%s\n' "$XTAB_BLOCK19" | grep -E '^execute[[:space:]]*\|' | head -1)"
case "$XEXEC_ROW19" in
  *30.00*) pass_msg "cross-tab execute×spawn cell == 30.00" ;;
  *) fail_msg "cross-tab execute row should carry spawn cell 30.00 (got: $XEXEC_ROW19)" ;;
esac
rm -rf "$TMP19"

# --- Scenario 20: --tokenomics net-out cache_read in per-PATH/issue size view (#721) ---
# Currently only the orchestrator stage row nets out cache_read (#668). Under
# --tokenomics, the per-issue "size" view reports tokens NET OF cache_read
# (input+output+cache_creation) for ALL rows. The DEFAULT emit_path_table
# (cache_read INCLUDED) stays byte-unchanged when --tokenomics is absent.
# Fixture: issue 220 with a huge cache_read:
#   input        1,000,000
#   cache_read  50,000,000
#   total       51,000,000
#   net-of-cache size = 1,000,000 (cache_read EXCLUDED).
inc_scenario "Scenario 20: --tokenomics net-out cache_read in per-PATH/issue size view"

TMP20="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP20/" 2>/dev/null
printf '%s\n' '[
  {"number":120,"title":"feat: per-issue size view","additions":300,"deletions":100,"body":"Closes #220","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP20/prs.json"
printf '%s\n' '{"number":120,"additions":300,"deletions":100,"comments":[]}' > "$TMP20/pr-120.json"
printf '%s\n' '{"number":220,"labels":[],"comments":[]}' > "$TMP20/issue-220.json"
{
  echo '{"schema_version":1,"issue":"220","stage":"execute","session_id":"s20","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K220","tokens":{"input":1000000,"output":0,"cache_read":50000000,"cache_creation":0,"total":51000000},"duration_ms":1000}'
} > "$TMP20/capture.jsonl"

# Default path table (no --tokenomics) reports the all-in total 51000000 → byte-unchanged.
DEF20="$(bash "$HELPER" --fixture "$TMP20" 2>/dev/null)"
PATH_ROW20="$(printf '%s\n' "$DEF20" | grep -E '^B[[:space:]]*\|' | head -1)"
case "$PATH_ROW20" in
  *51000000*) pass_msg "default per-PATH table keeps all-in tokens (51000000, cache_read INCLUDED)" ;;
  *) fail_msg "default per-PATH table should show all-in 51000000 (got: $PATH_ROW20)" ;;
esac
# Default output must NOT carry a net-of-cache size section.
if printf '%s' "$DEF20" | grep -qiE 'SIZE.*net|net.*cache_read'; then
  fail_msg "default output leaked a net-of-cache SIZE view"
else
  pass_msg "default output has no net-of-cache size view (gated behind --tokenomics)"
fi

TOK20="$(bash "$HELPER" --fixture "$TMP20" --tokenomics 2>/dev/null)"
# --tokenomics adds a per-issue net-of-cache size view.
SIZE_BLOCK20="$(printf '%s\n' "$TOK20" | awk '/SIZE \(net of cache_read\)|PER-ISSUE SIZE/{f=1} f')"
if [ -n "$SIZE_BLOCK20" ]; then
  pass_msg "--tokenomics renders a per-issue net-of-cache size view"
else
  fail_msg "--tokenomics missing per-issue net-of-cache size view"
fi
# Issue 220's net-of-cache size == 1000000 (cache_read excluded), NOT 51000000.
ISSUE_ROW20="$(printf '%s\n' "$SIZE_BLOCK20" | grep -E '220' | head -1)"
case "$ISSUE_ROW20" in
  *1000000*) ;;
  *) fail_msg "issue 220 net-of-cache size should contain 1000000 (got: $ISSUE_ROW20)" ;;
esac
# Parse the issue-220 row by pipe position (EXEC_SIZE18 style). With cache_read
# now a visible column the row shape is:
#   issue #220 | PATH | input | output | cache_read | net total
SIZE_IN20="$(printf '%s' "$ISSUE_ROW20" | awk -F'|' '{gsub(/[ ]/,"",$3); print $3}')"
SIZE_OUT20="$(printf '%s' "$ISSUE_ROW20" | awk -F'|' '{gsub(/[ ]/,"",$4); print $4}')"
SIZE_CR20="$(printf '%s' "$ISSUE_ROW20" | awk -F'|' '{gsub(/[ ]/,"",$5); print $5}')"
SIZE_NET20="$(printf '%s' "$ISSUE_ROW20" | awk -F'|' '{gsub(/[ ]/,"",$6); print $6}')"
if [ "$SIZE_IN20" = "1000000" ]; then
  pass_msg "issue 220 input column == 1000000"
else
  fail_msg "issue 220 input column should be 1000000, got $SIZE_IN20 (row=$ISSUE_ROW20)"
fi
if [ "$SIZE_OUT20" = "0" ]; then
  pass_msg "issue 220 output column == 0"
else
  fail_msg "issue 220 output column should be 0, got $SIZE_OUT20 (row=$ISSUE_ROW20)"
fi
if [ "$SIZE_CR20" = "50000000" ]; then
  pass_msg "issue 220 cache_read column == 50000000 (now a visible column)"
else
  fail_msg "issue 220 cache_read column should be 50000000, got $SIZE_CR20 (row=$ISSUE_ROW20)"
fi
if [ "$SIZE_NET20" = "1000000" ]; then
  pass_msg "issue 220 net total == 1000000 (net of cache_read)"
else
  fail_msg "issue 220 net total should be 1000000, got $SIZE_NET20 (row=$ISSUE_ROW20)"
fi
rm -rf "$TMP20"

# --- Scenario 21: --tokenomics B→D breakeven table (#721) ---
# For each PATH B issue in-window, project the savings if it had been routed
# PATH D instead. PATH D drops the plan + plan-eval ceremony stages (collapses
# execute to a single inline implementer). The MODELLED "saved" amount is the
# issue's plan + plan-eval stage cost; projected-D $ = current $ - saved.
# Fixture: PATH B issue 221 with three priced opus records (input-only, $15 each
# at Opus default 15/1M):
#   plan       input 1,000,000 → $15.00
#   plan-eval  input 1,000,000 → $15.00
#   execute    input 1,000,000 → $15.00
# current $ = 45.00 ; saved (plan+plan-eval) = 30.00 ; projected-D $ = 15.00.
inc_scenario "Scenario 21: --tokenomics B→D breakeven table"

TMP21="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP21/" 2>/dev/null
printf '%s\n' '[
  {"number":121,"title":"feat: breakeven issue","additions":300,"deletions":100,"body":"Closes #221","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP21/prs.json"
printf '%s\n' '{"number":121,"additions":300,"deletions":100,"comments":[]}' > "$TMP21/pr-121.json"
printf '%s\n' '{"number":221,"labels":[],"comments":[]}' > "$TMP21/issue-221.json"
{
  echo '{"schema_version":1,"issue":"221","stage":"plan","session_id":"s21a","model":"claude-opus-4-8","agent_kind":"inline","record_key":"K221P","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":900}'
  echo '{"schema_version":1,"issue":"221","stage":"plan-eval","session_id":"s21b","model":"claude-opus-4-8","agent_kind":"inline","record_key":"K221PE","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":800}'
  echo '{"schema_version":1,"issue":"221","stage":"execute","session_id":"s21c","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K221E","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1000}'
} > "$TMP21/capture.jsonl"

# Default (no --tokenomics): NO breakeven table.
DEF21="$(bash "$HELPER" --fixture "$TMP21" 2>/dev/null)"
if printf '%s' "$DEF21" | grep -qiE 'BREAKEVEN|B.*D'; then
  if printf '%s' "$DEF21" | grep -qi 'BREAKEVEN'; then
    fail_msg "default output (no --tokenomics) leaked a BREAKEVEN table"
  else
    pass_msg "default output has no breakeven table (gated behind --tokenomics)"
  fi
else
  pass_msg "default output has no breakeven table (gated behind --tokenomics)"
fi

TOK21="$(bash "$HELPER" --fixture "$TMP21" --tokenomics 2>/dev/null)"
if printf '%s' "$TOK21" | grep -qi 'BREAKEVEN'; then
  pass_msg "--tokenomics renders a B→D breakeven table"
else
  fail_msg "--tokenomics missing B→D breakeven table header"
fi

BE_BLOCK21="$(printf '%s\n' "$TOK21" | awk '/BREAKEVEN/{f=1} f')"
BE_ROW21="$(printf '%s\n' "$BE_BLOCK21" | grep -E '221' | head -1)"
# Row should carry current 45.00, projected-D 15.00, savings 30.00.
case "$BE_ROW21" in
  *45.00*) pass_msg "breakeven issue 221 current \$ == 45.00" ;;
  *) fail_msg "breakeven issue 221 current \$ should be 45.00 (got: $BE_ROW21)" ;;
esac
case "$BE_ROW21" in
  *15.00*) pass_msg "breakeven issue 221 projected-D \$ == 15.00" ;;
  *) fail_msg "breakeven issue 221 projected-D \$ should be 15.00 (got: $BE_ROW21)" ;;
esac
case "$BE_ROW21" in
  *30.00*) pass_msg "breakeven issue 221 savings == 30.00 (plan+plan-eval cost)" ;;
  *) fail_msg "breakeven issue 221 savings should be 30.00 (got: $BE_ROW21)" ;;
esac
# Aggregate total savings line == 30.00.
BE_TOTAL21="$(printf '%s\n' "$BE_BLOCK21" | grep -iE 'TOTAL|aggregate' | head -1)"
case "$BE_TOTAL21" in
  *30.00*) pass_msg "breakeven aggregate total savings == 30.00" ;;
  *) fail_msg "breakeven aggregate total savings should be 30.00 (got: $BE_TOTAL21)" ;;
esac
rm -rf "$TMP21"

# --- Scenario 22: --tokenomics coverage-health block (#721) ---
# A single block reporting:
#   - execute-stage record N;
#   - % feature PRs joined = joined ÷ eligible (reuse SKIPPED_NO_LINK + PR_COUNT);
#   - model-attribution coverage % = priced records ÷ total records (exposes #699).
# Fixture: ONE eligible feature PR #122 → issue 222 with TWO capture records:
#   execute / priced (opus)   — counts toward execute-N + priced.
#   plan    / unpriced (model:"") — drags model-attribution to 50%.
# joined = 1, eligible = 1 → 100%. priced 1 / total 2 → 50.0%.
inc_scenario "Scenario 22: --tokenomics coverage-health block"

TMP22="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP22/" 2>/dev/null
printf '%s\n' '[
  {"number":122,"title":"feat: coverage issue","additions":300,"deletions":100,"body":"Closes #222","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP22/prs.json"
printf '%s\n' '{"number":122,"additions":300,"deletions":100,"comments":[]}' > "$TMP22/pr-122.json"
printf '%s\n' '{"number":222,"labels":[],"comments":[]}' > "$TMP22/issue-222.json"
{
  echo '{"schema_version":1,"issue":"222","stage":"execute","session_id":"s22a","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K222E","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"222","stage":"plan","session_id":"s22b","model":"","agent_kind":"inline","record_key":"K222P","tokens":{"input":500000,"output":0,"cache_read":0,"cache_creation":0,"total":500000},"duration_ms":900}'
} > "$TMP22/capture.jsonl"

# Default (no --tokenomics): NO coverage-health block.
DEF22="$(bash "$HELPER" --fixture "$TMP22" 2>/dev/null)"
if printf '%s' "$DEF22" | grep -qi 'COVERAGE'; then
  fail_msg "default output (no --tokenomics) leaked a COVERAGE block"
else
  pass_msg "default output has no coverage-health block (gated behind --tokenomics)"
fi

TOK22="$(bash "$HELPER" --fixture "$TMP22" --tokenomics 2>/dev/null)"
COV_BLOCK22="$(printf '%s\n' "$TOK22" | awk '/COVERAGE/{f=1} f')"
if [ -n "$COV_BLOCK22" ]; then
  pass_msg "--tokenomics renders a coverage-health block"
else
  fail_msg "--tokenomics missing coverage-health block header"
fi

# execute-stage record N == 1.
case "$COV_BLOCK22" in
  *"execute"*1*) pass_msg "coverage block surfaces execute-stage record N (1)" ;;
  *) fail_msg "coverage block should surface execute-stage N==1 (got: $COV_BLOCK22)" ;;
esac

# Coverage block no longer surfaces a missing-transcript skipped row (#746).
if printf '%s' "$COV_BLOCK22" | grep -qi 'missing transcript'; then
  fail_msg "coverage block should no longer surface a missing-transcript skipped line (got: $COV_BLOCK22)"
else
  pass_msg "coverage block no longer surfaces missing-transcript skipped line (#746)"
fi

# % feature PRs joined == 100.0% (joined 1 / eligible 1).
if printf '%s' "$COV_BLOCK22" | grep -qiE 'join'; then
  pass_msg "coverage block reports % feature PRs joined"
else
  fail_msg "coverage block missing % feature PRs joined (got: $COV_BLOCK22)"
fi
case "$COV_BLOCK22" in
  *100*) pass_msg "coverage block joined % == 100 (1/1)" ;;
  *) fail_msg "coverage block joined % should be 100 (got: $COV_BLOCK22)" ;;
esac

# model-attribution coverage % == 50.0% (priced 1 / total 2).
if printf '%s' "$COV_BLOCK22" | grep -qiE 'attribution|model'; then
  pass_msg "coverage block reports model-attribution coverage"
else
  fail_msg "coverage block missing model-attribution coverage (got: $COV_BLOCK22)"
fi
MODELLINE22="$(printf '%s\n' "$COV_BLOCK22" | grep -iE 'attribution|model' | head -1)"
case "$MODELLINE22" in
  *50*) pass_msg "model-attribution coverage == 50% (priced 1 / total 2, #699)" ;;
  *) fail_msg "model-attribution coverage should be 50% (got: $MODELLINE22)" ;;
esac
rm -rf "$TMP22"

# --- Scenario 23: --tokenomics per-day + per-PR $ trend with outlier flagging (#721) ---
# Per-day: bucket priced records by date(ts_start) (the YYYY-MM-DD prefix; skip
# records with empty ts_start). Per day: total $, output $, output%-of-cost.
# Outlier days flagged when day $ >= 40% of the window total (documented thresh).
# Per-PR: cost per merged feature PR via the PR→issue join.
# Fixture: issue 223 (PR #123), FOUR execute records (opus), one per day:
#   2026-05-10  input 1,000,000        → $15.00
#   2026-05-11  input 1,000,000        → $15.00
#   2026-05-12  input 8,000,000        → $120.00   ← outlier (120 >= 40% of 180 = 72)
#   2026-05-13  cache_read 20,000,000  → $30.00    (opus cache_read $1.50/1M)
# window total = $180.00. Days 05-10/05-11 ($15) and 05-13 ($30) are NOT outliers.
# The non-zero cache_read record is the regression guard for the per-PR/per-day
# off-by-one (a wrong $7 index coerces cache_read to 0 and fails loudly).
inc_scenario "Scenario 23: --tokenomics per-day + per-PR \$ trend with outlier flagging"

TMP23="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP23/" 2>/dev/null
printf '%s\n' '[
  {"number":123,"title":"feat: trend issue","additions":300,"deletions":100,"body":"Closes #223","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP23/prs.json"
printf '%s\n' '{"number":123,"additions":300,"deletions":100,"comments":[]}' > "$TMP23/pr-123.json"
printf '%s\n' '{"number":223,"labels":[],"comments":[]}' > "$TMP23/issue-223.json"
{
  echo '{"schema_version":1,"issue":"223","stage":"execute","session_id":"s23a","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K223A","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1000,"ts_start":"2026-05-10T09:00:00Z","ts_end":"2026-05-10T09:01:00Z"}'
  echo '{"schema_version":1,"issue":"223","stage":"execute","session_id":"s23b","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K223B","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1000,"ts_start":"2026-05-11T09:00:00Z","ts_end":"2026-05-11T09:01:00Z"}'
  echo '{"schema_version":1,"issue":"223","stage":"execute","session_id":"s23c","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K223C","tokens":{"input":8000000,"output":0,"cache_read":0,"cache_creation":0,"total":8000000},"duration_ms":1000,"ts_start":"2026-05-12T09:00:00Z","ts_end":"2026-05-12T09:01:00Z"}'
  echo '{"schema_version":1,"issue":"223","stage":"execute","session_id":"s23d","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K223D","tokens":{"input":0,"output":0,"cache_read":20000000,"cache_creation":0,"total":20000000},"duration_ms":1000,"ts_start":"2026-05-13T09:00:00Z","ts_end":"2026-05-13T09:01:00Z"}'
} > "$TMP23/capture.jsonl"

# Default (no --tokenomics): NO trend block.
DEF23="$(bash "$HELPER" --fixture "$TMP23" 2>/dev/null)"
if printf '%s' "$DEF23" | grep -qiE 'TREND|PER-DAY'; then
  fail_msg "default output (no --tokenomics) leaked a trend block"
else
  pass_msg "default output has no trend block (gated behind --tokenomics)"
fi

TOK23="$(bash "$HELPER" --fixture "$TMP23" --tokenomics 2>/dev/null)"
TREND_BLOCK23="$(printf '%s\n' "$TOK23" | awk '/TREND|PER-DAY/{f=1} f')"
if [ -n "$TREND_BLOCK23" ]; then
  pass_msg "--tokenomics renders a per-day trend block"
else
  fail_msg "--tokenomics missing per-day trend block"
fi

# Per-day rows for all four days.
for day in 2026-05-10 2026-05-11 2026-05-12 2026-05-13; do
  if printf '%s' "$TREND_BLOCK23" | grep -qF "$day"; then
    pass_msg "trend block has a row for $day"
  else
    fail_msg "trend block missing row for $day"
  fi
done

# 05-12 row carries 120.00 and an outlier flag; 05-10 row carries 15.00 and no flag.
DAY12_ROW23="$(printf '%s\n' "$TREND_BLOCK23" | grep -F '2026-05-12' | head -1)"
DAY10_ROW23="$(printf '%s\n' "$TREND_BLOCK23" | grep -F '2026-05-10' | head -1)"
case "$DAY12_ROW23" in
  *120.00*) pass_msg "05-12 day total \$ == 120.00" ;;
  *) fail_msg "05-12 day total \$ should be 120.00 (got: $DAY12_ROW23)" ;;
esac
if printf '%s' "$DAY12_ROW23" | grep -qiE 'outlier|\*|FLAG'; then
  pass_msg "05-12 outlier day is flagged"
else
  fail_msg "05-12 outlier day should be flagged (got: $DAY12_ROW23)"
fi
case "$DAY10_ROW23" in
  *15.00*) pass_msg "05-10 day total \$ == 15.00" ;;
  *) fail_msg "05-10 day total \$ should be 15.00 (got: $DAY10_ROW23)" ;;
esac
if printf '%s' "$DAY10_ROW23" | grep -qiE 'outlier|FLAG'; then
  fail_msg "05-10 normal day should NOT be flagged (got: $DAY10_ROW23)"
else
  pass_msg "05-10 normal day is not flagged"
fi

# Per-day token columns (pipe-position parse). New column order:
#   date | input | output | cache_read | $ total | $ output | output%-of-cost
# 05-12 row carries input 8,000,000 / output 0 / cache_read 0.
DAY12_IN23="$(printf '%s' "$DAY12_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$2); print $2}')"
DAY12_OUT23="$(printf '%s' "$DAY12_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$3); print $3}')"
DAY12_CR23="$(printf '%s' "$DAY12_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$4); print $4}')"
if [ "$DAY12_IN23" = "8000000" ]; then
  pass_msg "05-12 input column == 8000000"
else
  fail_msg "05-12 input column should be 8000000, got $DAY12_IN23 (row=$DAY12_ROW23)"
fi
if [ "$DAY12_OUT23" = "0" ]; then
  pass_msg "05-12 output column == 0"
else
  fail_msg "05-12 output column should be 0, got $DAY12_OUT23 (row=$DAY12_ROW23)"
fi
if [ "$DAY12_CR23" = "0" ]; then
  pass_msg "05-12 cache_read column == 0"
else
  fail_msg "05-12 cache_read column should be 0, got $DAY12_CR23 (row=$DAY12_ROW23)"
fi

# 05-13 row: cache_read 20,000,000 (input/output 0), $ total 30.00, NOT flagged.
# The cache_read==20000000 assertion is the per-day off-by-one regression guard.
DAY13_ROW23="$(printf '%s\n' "$TREND_BLOCK23" | grep -F '2026-05-13' | head -1)"
DAY13_IN23="$(printf '%s' "$DAY13_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$2); print $2}')"
DAY13_OUT23="$(printf '%s' "$DAY13_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$3); print $3}')"
DAY13_CR23="$(printf '%s' "$DAY13_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$4); print $4}')"
if [ "$DAY13_IN23" = "0" ]; then
  pass_msg "05-13 input column == 0"
else
  fail_msg "05-13 input column should be 0, got $DAY13_IN23 (row=$DAY13_ROW23)"
fi
if [ "$DAY13_OUT23" = "0" ]; then
  pass_msg "05-13 output column == 0"
else
  fail_msg "05-13 output column should be 0, got $DAY13_OUT23 (row=$DAY13_ROW23)"
fi
if [ "$DAY13_CR23" = "20000000" ]; then
  pass_msg "05-13 cache_read column == 20000000 (off-by-one guard)"
else
  fail_msg "05-13 cache_read column should be 20000000, got $DAY13_CR23 (row=$DAY13_ROW23)"
fi
case "$DAY13_ROW23" in
  *30.00*) pass_msg "05-13 day total \$ == 30.00 (cache_read priced)" ;;
  *) fail_msg "05-13 day total \$ should be 30.00 (got: $DAY13_ROW23)" ;;
esac
if printf '%s' "$DAY13_ROW23" | grep -qiE 'outlier|FLAG'; then
  fail_msg "05-13 normal day should NOT be flagged (got: $DAY13_ROW23)"
else
  pass_msg "05-13 normal day is not flagged"
fi

# Per-PR $ section: PR #123 costs $180.00 (all four records join to issue 223).
PERPR_BLOCK23="$(printf '%s\n' "$TOK23" | awk '/PER-PR|PR \$|per-PR/{f=1} f')"
if printf '%s' "$PERPR_BLOCK23" | grep -qE '123'; then
  pass_msg "per-PR \$ section references PR #123"
else
  fail_msg "per-PR \$ section missing PR #123 (got: $PERPR_BLOCK23)"
fi
PERPR_ROW23="$(printf '%s\n' "$PERPR_BLOCK23" | grep -E '123' | head -1)"
case "$PERPR_ROW23" in
  *180.00*) pass_msg "per-PR \$ for PR #123 == 180.00 (sum of all four days)" ;;
  *) fail_msg "per-PR \$ for PR #123 should be 180.00 (got: $PERPR_ROW23)" ;;
esac
# Per-PR token columns (pipe-position parse). New column order:
#   PR # | input | output | cache_read | $ total
# PR #123 sums input 10,000,000 / output 0 / cache_read 20,000,000 over its four
# records. cache_read==20000000 is the per-PR off-by-one regression guard.
PERPR_IN23="$(printf '%s' "$PERPR_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$2); print $2}')"
PERPR_OUT23="$(printf '%s' "$PERPR_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$3); print $3}')"
PERPR_CR23="$(printf '%s' "$PERPR_ROW23" | awk -F'|' '{gsub(/[ ]/,"",$4); print $4}')"
if [ "$PERPR_IN23" = "10000000" ]; then
  pass_msg "per-PR input column == 10000000"
else
  fail_msg "per-PR input column should be 10000000, got $PERPR_IN23 (row=$PERPR_ROW23)"
fi
if [ "$PERPR_OUT23" = "0" ]; then
  pass_msg "per-PR output column == 0"
else
  fail_msg "per-PR output column should be 0, got $PERPR_OUT23 (row=$PERPR_ROW23)"
fi
if [ "$PERPR_CR23" = "20000000" ]; then
  pass_msg "per-PR cache_read column == 20000000 (off-by-one guard)"
else
  fail_msg "per-PR cache_read column should be 20000000, got $PERPR_CR23 (row=$PERPR_ROW23)"
fi
rm -rf "$TMP23"

# --- Scenario 24: --tokenomics spawn vs inline task-latency split, unpriced-honest (#721, #789) ---
# Task latency is split into TWO labelled rows (#789):
#   - spawn  = headless duration_ms (session-lifetime), labelled
#              "(session-lifetime, not task-latency)";
#   - inline = median over agent_kind != "headless" records (true task-latency),
#              sourced from CAPTURE_JSON (ALL records, NOT priced_duration_tsv) so
#              a LIVE unpriced inline (model="") is NOT gated out of the median.
# Durations render in MINUTES (#789 Task 1). The 5.4M ms value appears only on the
# spawn row, never folded into the inline median.
# Fixture: issue 224 (PR #124), three records (#789 LIVE shape — inline model=""):
#   headless execute  duration 5,400,000 ms (= 90.0 min) ← spawn, session-lifetime
#   inline   plan      duration 60,000 ms  UNPRICED (model="")
#   inline   plan-eval duration 120,000 ms UNPRICED (model="")
# inline median = median(60000,120000) = 90000 ms = 1.5 min, NON-ZERO on unpriced.
inc_scenario "Scenario 24: --tokenomics spawn vs inline task-latency split (unpriced-honest)"

TMP24="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP24/" 2>/dev/null
printf '%s\n' '[
  {"number":124,"title":"feat: headless duration issue","additions":300,"deletions":100,"body":"Closes #224","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP24/prs.json"
printf '%s\n' '{"number":124,"additions":300,"deletions":100,"comments":[]}' > "$TMP24/pr-124.json"
printf '%s\n' '{"number":224,"labels":[],"comments":[]}' > "$TMP24/issue-224.json"
{
  echo '{"schema_version":1,"issue":"224","stage":"execute","session_id":"s24a","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K224E","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":5400000,"ts_start":"2026-05-12T09:00:00Z","ts_end":"2026-05-12T10:30:00Z"}'
  echo '{"schema_version":1,"issue":"224","stage":"plan","session_id":"s24b","model":"","agent_kind":"inline","record_key":"K224P","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":60000,"ts_start":"2026-05-12T08:00:00Z","ts_end":"2026-05-12T08:00:00Z"}'
  echo '{"schema_version":1,"issue":"224","stage":"plan-eval","session_id":"s24c","model":"","agent_kind":"inline","record_key":"K224PE","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":120000,"ts_start":"2026-05-12T08:05:00Z","ts_end":"2026-05-12T08:05:00Z"}'
} > "$TMP24/capture.jsonl"

TOK24="$(bash "$HELPER" --fixture "$TMP24" --tokenomics 2>/dev/null)"

# (a) Headless/spawn duration is annotated "(session-lifetime, not task-latency)".
if printf '%s' "$TOK24" | grep -qF '(session-lifetime, not task-latency)'; then
  pass_msg "spawn duration annotated '(session-lifetime, not task-latency)'"
else
  fail_msg "spawn duration should be annotated '(session-lifetime, not task-latency)'"
fi

LAT_BLOCK24="$(printf '%s\n' "$TOK24" | awk '/TASK LATENCY/{f=1} f')"
if [ -n "$LAT_BLOCK24" ]; then
  pass_msg "--tokenomics renders a task-latency block"
else
  fail_msg "--tokenomics missing a task-latency block"
fi

# (b) TWO labelled rows: spawn and inline.
SPAWN_LAT24="$(printf '%s\n' "$LAT_BLOCK24" | grep -E '^spawn[[:space:]]*\|' | head -1)"
INLINE_LAT24="$(printf '%s\n' "$LAT_BLOCK24" | grep -E '^inline[[:space:]]*\|' | head -1)"
if [ -n "$SPAWN_LAT24" ]; then pass_msg "task-latency has a 'spawn' row"; else fail_msg "task-latency should have a 'spawn' row (got: $LAT_BLOCK24)"; fi
if [ -n "$INLINE_LAT24" ]; then pass_msg "task-latency has an 'inline' row"; else fail_msg "task-latency should have an 'inline' row (got: $LAT_BLOCK24)"; fi

# (c) spawn row carries the session-lifetime label.
case "$SPAWN_LAT24" in
  *session-lifetime*) pass_msg "spawn row labelled session-lifetime, not task-latency" ;;
  *) fail_msg "spawn row should carry the session-lifetime label (got: $SPAWN_LAT24)" ;;
esac

# (d) inline row median == 1.5 min (90000 ms), NON-ZERO on LIVE unpriced inline.
INLINE_DUR24="$(printf '%s' "$INLINE_LAT24" | awk -F'|' '{gsub(/[ ]/,"",$NF); print $NF}')"
if [ "$INLINE_DUR24" = "1.5" ]; then
  pass_msg "inline task-latency == 1.5 min (median 90000 ms, sourced from all records — unpriced not gated out)"
else
  fail_msg "inline task-latency should be 1.5 min (NON-ZERO on unpriced inline), got '$INLINE_DUR24' (row=$INLINE_LAT24)"
fi
case "$INLINE_DUR24" in
  0|0.0|--) fail_msg "inline task-latency row is ZERO/-- — unpriced inline was gated out (priced-gate pathology)" ;;
  *) pass_msg "inline task-latency row is non-zero on live unpriced inline" ;;
esac

# (e) the 5.4M ms session-lifetime value appears only on the spawn row, never in
# the inline median (which renders 1.5 min, not 90.0).
case "$INLINE_LAT24" in
  *5400000*|*90.0*) fail_msg "inline row leaked the headless session-lifetime duration (got: $INLINE_LAT24)" ;;
  *) pass_msg "inline row excludes the headless session-lifetime duration" ;;
esac
rm -rf "$TMP24"

# --- Scenario 25: --tokenomics concurrency assessment (observed overlap + ceiling) (#721) ---
# Data-derived (per docs/cost-architecture.md §8): count overlapping
# [ts_start, ts_end] intervals among EXECUTE-stage headless records (sweep-line),
# report the MAX observed concurrent execute count, and a stated ceiling text =
# min(rate-limit ceiling, cwd-isolation-safe count) referencing §8, plus the
# observed number.
# Fixture: issue 225 (PR #125), THREE execute headless records whose intervals
# all overlap in the 09:20–09:25 window → max observed concurrency == 3:
#   s1  09:00:00 – 09:30:00
#   s2  09:10:00 – 09:40:00
#   s3  09:20:00 – 09:25:00
inc_scenario "Scenario 25: --tokenomics concurrency assessment (observed overlap + ceiling)"

TMP25="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP25/" 2>/dev/null
printf '%s\n' '[
  {"number":125,"title":"feat: concurrency issue","additions":300,"deletions":100,"body":"Closes #225","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP25/prs.json"
printf '%s\n' '{"number":125,"additions":300,"deletions":100,"comments":[]}' > "$TMP25/pr-125.json"
printf '%s\n' '{"number":225,"labels":[],"comments":[]}' > "$TMP25/issue-225.json"
{
  echo '{"schema_version":1,"issue":"225","stage":"execute","session_id":"c1","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K225A","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1800000,"ts_start":"2026-05-12T09:00:00Z","ts_end":"2026-05-12T09:30:00Z"}'
  echo '{"schema_version":1,"issue":"225","stage":"execute","session_id":"c2","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K225B","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1800000,"ts_start":"2026-05-12T09:10:00Z","ts_end":"2026-05-12T09:40:00Z"}'
  echo '{"schema_version":1,"issue":"225","stage":"execute","session_id":"c3","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K225C","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":300000,"ts_start":"2026-05-12T09:20:00Z","ts_end":"2026-05-12T09:25:00Z"}'
} > "$TMP25/capture.jsonl"

# Default (no --tokenomics): NO concurrency assessment.
DEF25="$(bash "$HELPER" --fixture "$TMP25" 2>/dev/null)"
if printf '%s' "$DEF25" | grep -qi 'CONCURRENCY'; then
  fail_msg "default output (no --tokenomics) leaked a concurrency assessment"
else
  pass_msg "default output has no concurrency assessment (gated behind --tokenomics)"
fi

TOK25="$(bash "$HELPER" --fixture "$TMP25" --tokenomics 2>/dev/null)"
CONC_BLOCK25="$(printf '%s\n' "$TOK25" | awk '/CONCURRENCY/{f=1} f')"
if [ -n "$CONC_BLOCK25" ]; then
  pass_msg "--tokenomics renders a concurrency assessment block"
else
  fail_msg "--tokenomics missing concurrency assessment block"
fi

# Max observed concurrency == 3.
if printf '%s' "$CONC_BLOCK25" | grep -qE '(max|observed).*3|3.*concurren'; then
  pass_msg "concurrency assessment reports max observed concurrency == 3"
else
  fail_msg "concurrency assessment should report max observed concurrency 3 (got: $CONC_BLOCK25)"
fi

# Assessment text references the §8 ceiling = min(rate-limit, cwd-isolation-safe).
if printf '%s' "$CONC_BLOCK25" | grep -qiE 'ceiling'; then
  pass_msg "concurrency assessment surfaces the ceiling framing"
else
  fail_msg "concurrency assessment missing ceiling framing (got: $CONC_BLOCK25)"
fi
if printf '%s' "$CONC_BLOCK25" | grep -qiE '§8|section 8|cost-architecture'; then
  pass_msg "concurrency assessment references docs/cost-architecture.md §8"
else
  fail_msg "concurrency assessment should reference §8 (got: $CONC_BLOCK25)"
fi
if printf '%s' "$CONC_BLOCK25" | grep -qiE 'rate.?limit'; then
  pass_msg "concurrency ceiling references rate-limit"
else
  fail_msg "concurrency ceiling should mention rate-limit (got: $CONC_BLOCK25)"
fi
if printf '%s' "$CONC_BLOCK25" | grep -qiE 'cwd|isolation'; then
  pass_msg "concurrency ceiling references cwd-isolation"
else
  fail_msg "concurrency ceiling should mention cwd-isolation (got: $CONC_BLOCK25)"
fi
rm -rf "$TMP25"

# --- Scenario 26: tokenomics-report fixture renders all --tokenomics tables non-zero (#721) ---
# A SINGLE standing, model-bearing golden fixture (tests/fixtures/tokenomics-report)
# that drives a RICH non-zero --tokenomics demo (the base cost-latency-report
# fixture has no `model` field, so its $ tables render all-zero). This is the
# fixture the /pipeline:tokenomics skill (Task 6) showcases. The fixture exercises
# EVERY new dimension; this scenario runs the report ONCE and asserts golden values.
#
# Surviving PRICED records (model="claude-opus-4-8") after both dedup passes, with
# their all-four-bucket $ at Opus default rates (per 1M: in 15, out 75, cc 18.75,
# cr 1.50):
#   301-plan      in 1.0M out 0.2M cc 2.0M cr 4.0M  → 15+15+37.5+6   = $ 73.50
#   301-plan-eval in 0.5M out 0.1M cc 1.0M cr 2.0M  → 7.5+7.5+18.75+3= $ 36.75
#   301-execute   in 2.0M out 1.0M cc 4.0M cr 10.0M → 30+75+75+15    = $195.00  (max-total winner of a dup)
#   301-pr-eval   in 0.8M out 0.2M cc 1.0M cr 3.0M  → 12+15+18.75+4.5= $ 50.25
#   302-plan      in 0.4M out 0.1M cc 0.8M cr 1.0M  → 6+7.5+15+1.5   = $ 30.00
#   302-execute   in 1.0M out 0.5M cc 2.0M cr 5.0M  → 15+37.5+37.5+7.5=$ 97.50
#   303-execute-b in 4.0M out 4.0M cc 8.0M cr 20.0M → 60+300+150+30  = $540.00  (session sB)
#   303-execute-c in 3.0M out 3.0M cc 6.0M cr 15.0M → 45+225+112.5+22.5=$405.00 (session sC; multi-session re-run preserved)
#   orch-final    in 5.0M out 2.0M cc 0   cr 0      → 75+150+0+0     = $225.00  (N snapshots collapse to this max-total)
#                                                          PRICED $ TOTAL = $1653.00
# Plus ONE UNPRICED inline record (model="") → excluded from $, COUNTED → coverage 9/10 = 90.0%.
inc_scenario "Scenario 26: tokenomics-report fixture renders all --tokenomics tables non-zero"

TOKFIX="$REPO_ROOT/tests/fixtures/tokenomics-report"

# Run ONCE with Opus defaults (strip any ambient PIPELINE_PRICE_* override),
# capture all --tokenomics output.
TOK26="$(env -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT \
             -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT \
             -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION \
             -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ \
         bash "$HELPER" --fixture "$TOKFIX" --tokenomics 2>/dev/null)"

# (a) every table SECTION header present.
for hdr in 'BUCKET' 'STAGE COST' 'STRUCTURE' 'STAGE x STRUCTURE' 'B→D BREAKEVEN' \
           'COVERAGE HEALTH' 'TREND (per-day)' 'CONCURRENCY ASSESSMENT'; do
  if printf '%s' "$TOK26" | grep -qF "$hdr"; then
    pass_msg "tokenomics-report: section header present: $hdr"
  else
    fail_msg "tokenomics-report: missing section header: $hdr"
  fi
done

# (b) priced $ total == $1653.00 (golden; arithmetic in the comment above).
COST26="$(env -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT \
              -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT \
              -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION \
              -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ \
          bash "$HELPER" --fixture "$TOKFIX" --emit-pricing-json 2>/dev/null \
          | jq -r '.priced_cost_usd' 2>/dev/null)"
if [ "$COST26" = "1653.00" ]; then
  pass_msg "tokenomics-report: priced \$ total == 1653.00 (exact golden)"
else
  fail_msg "tokenomics-report: priced \$ total should be 1653.00, got $COST26"
fi

# Bucket table $ is the SAME total (sum of the four bucket $ rows).
BUCKET_USD_SUM26="$(printf '%s\n' "$TOK26" \
  | awk -F'|' '/^(input|output|cache_creation|cache_read)[[:space:]]*\|/ {gsub(/[ $]/,"",$3); s+=$3} END{printf "%.2f", s}')"
if [ "$BUCKET_USD_SUM26" = "1653.00" ]; then
  pass_msg "tokenomics-report: bucket table \$ sums to 1653.00 (matches priced total)"
else
  fail_msg "tokenomics-report: bucket \$ rows should sum to 1653.00, got $BUCKET_USD_SUM26"
fi

# (c) token-share != cost-share: output cost% > token%; cache_read cost% < token%.
OUT_ROW26="$(printf '%s\n' "$TOK26" | grep -E '^output[[:space:]]*\|' | head -1)"
CR_ROW26="$(printf '%s\n' "$TOK26" | grep -E '^cache_read[[:space:]]*\|' | head -1)"
OUT_COSTPCT26="$(printf '%s' "$OUT_ROW26" | awk -F'|' '{gsub(/[ %]/,"",$4); print $4+0}')"
OUT_TOKPCT26="$(printf '%s' "$OUT_ROW26" | awk -F'|' '{gsub(/[ %]/,"",$5); print $5+0}')"
CR_COSTPCT26="$(printf '%s' "$CR_ROW26" | awk -F'|' '{gsub(/[ %]/,"",$4); print $4+0}')"
CR_TOKPCT26="$(printf '%s' "$CR_ROW26" | awk -F'|' '{gsub(/[ %]/,"",$5); print $5+0}')"
if awk -v c="$OUT_COSTPCT26" -v t="$OUT_TOKPCT26" 'BEGIN{exit !(c>t)}'; then
  pass_msg "tokenomics-report: output cost% ($OUT_COSTPCT26) > token% ($OUT_TOKPCT26)"
else
  fail_msg "tokenomics-report: output cost% should exceed token% (cost%=$OUT_COSTPCT26 token%=$OUT_TOKPCT26)"
fi
if awk -v c="$CR_COSTPCT26" -v t="$CR_TOKPCT26" 'BEGIN{exit !(c<t)}'; then
  pass_msg "tokenomics-report: cache_read cost% ($CR_COSTPCT26) < token% ($CR_TOKPCT26)"
else
  fail_msg "tokenomics-report: cache_read cost% should be below token% (cost%=$CR_COSTPCT26 token%=$CR_TOKPCT26)"
fi

# (d) model-attribution coverage == 9/10 (90.0%) — one empty-model record present.
if printf '%s' "$TOK26" | grep -qE 'model-attribution coverage: 9/10 \(90\.0%\)'; then
  pass_msg "tokenomics-report: model-attribution coverage == 9/10 (90.0%)"
else
  fail_msg "tokenomics-report: coverage should be 9/10 (90.0%), got: $(printf '%s' "$TOK26" | grep -i 'model-attribution')"
fi

# (e) outlier day flagged: 2026-05-22 (57.2% of window > 40% threshold).
OUTLIER_ROW26="$(printf '%s\n' "$TOK26" | grep -E '2026-05-22.*OUTLIER')"
if [ -n "$OUTLIER_ROW26" ]; then
  pass_msg "tokenomics-report: outlier day 2026-05-22 flagged"
else
  fail_msg "tokenomics-report: 2026-05-22 should be flagged *OUTLIER (got trend: $(printf '%s\n' "$TOK26" | grep 2026-05))"
fi
# The two non-outlier days must NOT be flagged.
if printf '%s\n' "$TOK26" | grep -E '2026-05-2[01].*OUTLIER' >/dev/null; then
  fail_msg "tokenomics-report: a non-outlier day (05-20/05-21) was wrongly flagged OUTLIER"
else
  pass_msg "tokenomics-report: non-outlier days (05-20, 05-21) not flagged"
fi

# (f) concurrency observed-max == 3 (three overlapping execute intervals).
CONC_BLOCK26="$(printf '%s\n' "$TOK26" | awk '/CONCURRENCY/{f=1} f')"
if printf '%s' "$CONC_BLOCK26" | grep -qE 'max observed concurrent execute workers: 3'; then
  pass_msg "tokenomics-report: concurrency observed-max == 3"
else
  fail_msg "tokenomics-report: concurrency observed-max should be 3 (got: $CONC_BLOCK26)"
fi

# (g) headless ~5.4M ms session-lifetime durations annotated + the inline
# task-latency row must NOT carry the 5.4M value (#789 spawn/inline split). The
# 5400000 value appears in the HEADLESS DURATIONS block and on the spawn row, but
# never folded into the inline row's median.
HEADLESS_DUR_BLOCK26="$(printf '%s\n' "$TOK26" | awk '/HEADLESS DURATIONS/{f=1} /TASK LATENCY/{f=0} f')"
if printf '%s' "$HEADLESS_DUR_BLOCK26" | grep -qE '5400000.*session-lifetime'; then
  pass_msg "tokenomics-report: 5.4M ms headless duration annotated session-lifetime"
else
  fail_msg "tokenomics-report: 5400000 should be annotated session-lifetime (got: $HEADLESS_DUR_BLOCK26)"
fi
# The TASK LATENCY block carries TWO labelled rows (spawn, inline).
LAT_BLOCK26="$(printf '%s\n' "$TOK26" | awk '/TASK LATENCY/{f=1} f')"
SPAWN_LAT26="$(printf '%s\n' "$LAT_BLOCK26" | grep -E '^spawn[[:space:]]*\|' | head -1)"
INLINE_LAT26="$(printf '%s\n' "$LAT_BLOCK26" | grep -E '^inline[[:space:]]*\|' | head -1)"
if [ -n "$SPAWN_LAT26" ] && [ -n "$INLINE_LAT26" ]; then
  pass_msg "tokenomics-report: task-latency has both spawn and inline rows"
else
  fail_msg "tokenomics-report: task-latency should have spawn + inline rows (got: $LAT_BLOCK26)"
fi
# The inline row's median (rendered in minutes) must NOT be the 5.4M/90.0-min value.
case "$INLINE_LAT26" in
  *90.0*|*5400000*) fail_msg "tokenomics-report: inline task-latency leaked the headless session-lifetime duration ($INLINE_LAT26)" ;;
  *) pass_msg "tokenomics-report: 5.4M ms headless duration excluded from inline task-latency" ;;
esac

# (h) breakeven has real PATH B rows (301, 302) and a positive TOTAL savings.
if printf '%s' "$TOK26" | grep -qE 'issue #301' && printf '%s' "$TOK26" | grep -qE 'issue #302'; then
  pass_msg "tokenomics-report: breakeven lists PATH B issues 301 and 302"
else
  fail_msg "tokenomics-report: breakeven should list PATH B issues 301 and 302"
fi
# 301 saved = plan(73.50)+plan-eval(36.75)=110.25; 302 saved = plan(30.00); TOTAL=140.25.
BE_TOTAL26="$(printf '%s\n' "$TOK26" | grep -E '^TOTAL[[:space:]]*\|' | awk -F'|' '{gsub(/[ ]/,"",$4); print $4}')"
if [ "$BE_TOTAL26" = "140.25" ]; then
  pass_msg "tokenomics-report: breakeven TOTAL savings == 140.25 (golden: 73.50+36.75+30.00)"
else
  fail_msg "tokenomics-report: breakeven TOTAL savings should be 140.25, got $BE_TOTAL26"
fi

# --- Scenario 27: per-model baked defaults — Sonnet & Haiku price at own rates (#733) ---
# Non-Opus models must price at their OWN baked list-price defaults, not the
# Opus rates. Two priced records (Sonnet 4.6 + Haiku 4.5) with round 1,000,000
# tokens per bucket so the golden $ is exact at the baked per-model rates:
#   Sonnet (3/15/3.75/0.30):  1*3 + 1*15 + 1*3.75 + 1*0.30  = $22.05
#   Haiku  (1/5/1.25/0.10):   1*1 + 1*5  + 1*1.25 + 1*0.10  =  $7.35
#                                                    COMBINED = $29.40
# At the OLD Opus-only fallback both records would price at 15/75/18.75/1.50 =
# $110.25 each → $220.50. Assert == 29.40 AND != 220.* so this fails RED against
# current code for the RIGHT reason (Opus fallback applied to non-Opus models).
inc_scenario "Scenario 27: per-model baked defaults (Sonnet+Haiku price at own rates, not Opus)"

TMP27="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP27/" 2>/dev/null
printf '%s\n' '[
  {"number":127,"title":"feat: sonnet record issue","additions":300,"deletions":100,"body":"Closes #227","mergedAt":"2026-05-13T12:00:00Z","labels":[]},
  {"number":128,"title":"feat: haiku record issue","additions":50,"deletions":20,"body":"Closes #228","mergedAt":"2026-05-13T13:00:00Z","labels":[]}
]' > "$TMP27/prs.json"
printf '%s\n' '{"number":127,"additions":300,"deletions":100,"comments":[]}' > "$TMP27/pr-127.json"
printf '%s\n' '{"number":227,"labels":[],"comments":[]}' > "$TMP27/issue-227.json"
printf '%s\n' '{"number":128,"additions":50,"deletions":20,"comments":[]}' > "$TMP27/pr-128.json"
printf '%s\n' '{"number":228,"labels":[],"comments":[]}' > "$TMP27/issue-228.json"
{
  echo '{"schema_version":1,"issue":"227","stage":"execute","session_id":"s27a","model":"claude-sonnet-4-6","agent_kind":"headless","record_key":"K227","tokens":{"input":1000000,"output":1000000,"cache_read":1000000,"cache_creation":1000000,"total":4000000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"228","stage":"execute","session_id":"s27b","model":"claude-haiku-4-5","agent_kind":"headless","record_key":"K228","tokens":{"input":1000000,"output":1000000,"cache_read":1000000,"cache_creation":1000000,"total":4000000},"duration_ms":900}'
} > "$TMP27/capture.jsonl"

# Drive with env -u of every PIPELINE_PRICE_* key for these models so the
# assertion exercises BAKED defaults, not ambient env (mirror Scenario 16).
PRICING27="$(env -u PIPELINE_PRICE_CLAUDE_SONNET_4_6_INPUT \
                 -u PIPELINE_PRICE_CLAUDE_SONNET_4_6_OUTPUT \
                 -u PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_CREATION \
                 -u PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_READ \
                 -u PIPELINE_PRICE_CLAUDE_HAIKU_4_5_INPUT \
                 -u PIPELINE_PRICE_CLAUDE_HAIKU_4_5_OUTPUT \
                 -u PIPELINE_PRICE_CLAUDE_HAIKU_4_5_CACHE_CREATION \
                 -u PIPELINE_PRICE_CLAUDE_HAIKU_4_5_CACHE_READ \
             bash "$HELPER" --fixture "$TMP27" --emit-pricing-json 2>/dev/null)"

if printf '%s' "$PRICING27" | jq -e . >/dev/null 2>&1; then
  pass_msg "--emit-pricing-json output parses as JSON"
else
  fail_msg "--emit-pricing-json output is not valid JSON (got: $(printf '%s' "$PRICING27" | head -1))"
fi

COST27="$(printf '%s' "$PRICING27" | jq -r '.priced_cost_usd' 2>/dev/null)"
if [ "$COST27" = "29.40" ] || [ "$COST27" = "29.4" ]; then
  pass_msg "priced_cost_usd == 29.40 (Sonnet 22.05 + Haiku 7.35 at baked per-model rates)"
else
  fail_msg "priced_cost_usd should be 29.40 (Sonnet+Haiku baked defaults), got $COST27"
fi

# Guard: prove the flat Opus fallback did NOT apply to the non-Opus records
# (Opus fallback would yield $220.50).
case "$COST27" in
  220*) fail_msg "priced_cost_usd applied the Opus fallback to non-Opus models (220.50)" ;;
  *) pass_msg "priced_cost_usd did NOT apply Opus fallback to Sonnet/Haiku (220.50 rejected)" ;;
esac
rm -rf "$TMP27"

# --- Scenario 28: backfill reconciliation (no double-count) + coverage lower-bound count (#773) ---
# Two facets of the inline-cost backfill landing at render time:
#   (a) For the SAME (session_id, issue, stage), a forward lower-bound record
#       (source:"forward", usage_complete:false, small total) and a retroactive
#       cumulative (source:"retroactive", usage_complete:true, large total)
#       coexist (record_key includes source). The (session,issue,stage) max-total
#       dedup MUST collapse them to the cumulative ONLY — no double-count. The
#       per-issue token sum equals the LARGE cumulative, not the sum of both.
#   (b) The COVERAGE HEALTH block reports how many DEDUPED records are still a
#       lower bound (usage_complete:false) so the operator knows the figure is a
#       floor for those rows. Deduped stream here has 2 records (the reconciled
#       cumulative for 229 + a standalone unreconciled lower-bound for 230), so
#       the count reads 1/2.
inc_scenario "Scenario 28: backfill reconciliation (no double-count) + coverage lower-bound count"

TMP28="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP28/" 2>/dev/null
printf '%s\n' '[
  {"number":129,"title":"feat: reconciled inline issue","additions":300,"deletions":100,"body":"Closes #229","mergedAt":"2026-05-13T12:00:00Z","labels":[]},
  {"number":130,"title":"feat: unreconciled lower-bound issue","additions":50,"deletions":20,"body":"Closes #230","mergedAt":"2026-05-13T13:00:00Z","labels":[]}
]' > "$TMP28/prs.json"
printf '%s\n' '{"number":129,"additions":300,"deletions":100,"comments":[]}' > "$TMP28/pr-129.json"
printf '%s\n' '{"number":229,"labels":[],"comments":[]}' > "$TMP28/issue-229.json"
printf '%s\n' '{"number":130,"additions":50,"deletions":20,"comments":[]}' > "$TMP28/pr-130.json"
printf '%s\n' '{"number":230,"labels":[],"comments":[]}' > "$TMP28/issue-230.json"
{
  # SAME (session s28, issue 229, stage execute): forward lower-bound (1115) +
  # retroactive cumulative (86310). DISTINCT record_key (source differs) → both
  # survive the record_key pass; (session,issue,stage) dedup keeps the cumulative.
  echo '{"schema_version":1,"issue":"229","stage":"execute","session_id":"s28","model":"","agent_kind":"inline","source":"forward","usage_complete":false,"record_key":"K229F","tokens":{"input":1000,"output":100,"cache_read":10,"cache_creation":5,"total":1115},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"229","stage":"execute","session_id":"s28","model":"claude-opus-4-8","agent_kind":"inline","source":"retroactive","usage_complete":true,"record_key":"K229R","tokens":{"input":1100,"output":110,"cache_read":81000,"cache_creation":4100,"total":86310},"duration_ms":1000}'
  # Standalone UNRECONCILED lower-bound for issue 230 (no transcript ever staged).
  echo '{"schema_version":1,"issue":"230","stage":"execute","session_id":"s28b","model":"","agent_kind":"inline","source":"forward","usage_complete":false,"record_key":"K230F","tokens":{"input":2000,"output":200,"cache_read":20,"cache_creation":10,"total":2230},"duration_ms":900}'
} > "$TMP28/capture.jsonl"

# (a) per-issue 229 token sum == 86310 (cumulative ONLY), NOT 87425 (naive both).
ROWS28="$(bash "$HELPER" --fixture "$TMP28" --emit-rows-json 2>/dev/null)"
TT28="$(printf '%s' "$ROWS28" | jq -r '.[] | select(.issue==229) | .tokens_total' 2>/dev/null)"
if [ "$TT28" = "86310" ]; then
  pass_msg "issue 229 tokens_total == 86310 (reconciled cumulative, no double-count)"
else
  fail_msg "issue 229 tokens_total should be 86310 (cumulative only), got $TT28"
fi
if [ "$TT28" = "87425" ]; then
  fail_msg "issue 229 tokens_total double-counted forward+retroactive (naive 87425)"
else
  pass_msg "issue 229 tokens_total excludes the forward lower-bound (naive 87425 rejected)"
fi

# (b) COVERAGE HEALTH carries a lower-bound (unreconciled) count == 1/2 over the
# deduped stream (reconciled 229 cumulative is true; standalone 230 is false).
TOK28="$(bash "$HELPER" --fixture "$TMP28" --tokenomics 2>/dev/null)"
COV_BLOCK28="$(printf '%s\n' "$TOK28" | awk '/COVERAGE/{f=1} f')"
LB_LINE28="$(printf '%s\n' "$COV_BLOCK28" | grep -iE 'lower-bound' | head -1)"
if [ -n "$LB_LINE28" ]; then
  pass_msg "coverage block reports a lower-bound (unreconciled) line"
else
  fail_msg "coverage block missing lower-bound (unreconciled) line (got: $COV_BLOCK28)"
fi
case "$LB_LINE28" in
  *1/2*) pass_msg "lower-bound (unreconciled) count == 1/2 (one false of two deduped)" ;;
  *) fail_msg "lower-bound count should be 1/2, got: $LB_LINE28" ;;
esac
rm -rf "$TMP28"

# --- Scenario 29: duration columns render in minutes, not ms (#789 Task 1) ---
# Every USER-FACING duration column switches to minutes (min = ms/60000, 1dp,
# '--' passthrough). Internal --emit-rows-json + metrics-snapshot stay in ms.
# Fixture: issue 229b (PR #131) PATH B with a 90000 ms (= 1.5 min) execute record.
# Per-PATH `median dur` header reads (min) and the value renders 1.5, NOT 90000.
inc_scenario "Scenario 29: duration columns render in minutes (#789)"

TMP29="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP29/" 2>/dev/null
printf '%s\n' '[
  {"number":131,"title":"feat: minutes unit issue","additions":300,"deletions":100,"body":"Closes #231","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP29/prs.json"
printf '%s\n' '{"number":131,"additions":300,"deletions":100,"comments":[]}' > "$TMP29/pr-131.json"
printf '%s\n' '{"number":231,"labels":[],"comments":[]}' > "$TMP29/issue-231.json"
{
  echo '{"schema_version":1,"issue":"231","stage":"execute","session_id":"s29","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K231","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":90000}'
} > "$TMP29/capture.jsonl"

TABLE29="$(bash "$HELPER" --fixture "$TMP29" 2>/dev/null)"

# (a) per-PATH table duration header reads (min), not (ms).
if printf '%s' "$TABLE29" | grep -qE 'median dur\(min\)'; then
  pass_msg "per-PATH/stage table duration header reads (min)"
else
  fail_msg "duration header should read median dur(min) (got: $(printf '%s\n' "$TABLE29" | grep -i 'PATH | N'))"
fi
if printf '%s' "$TABLE29" | grep -qE 'median dur\(ms\)'; then
  fail_msg "duration header still reads (ms) — minutes switch incomplete"
else
  pass_msg "no duration header reads (ms) any more"
fi

# (b) per-PATH B-row duration cell renders 1.5 (90000 ms / 60000), NOT 90000.
PATHB_ROW29="$(printf '%s\n' "$TABLE29" | grep -E '^B[[:space:]]*\|' | head -1)"
DUR_CELL29="$(printf '%s' "$PATHB_ROW29" | awk -F'|' '{gsub(/[ ]/,"",$5); print $5}')"
if [ "$DUR_CELL29" = "1.5" ]; then
  pass_msg "per-PATH B median dur == 1.5 min (90000 ms rendered in minutes)"
else
  fail_msg "per-PATH B median dur should be 1.5 min, got $DUR_CELL29 (row=$PATHB_ROW29)"
fi
case "$PATHB_ROW29" in
  *90000*) fail_msg "per-PATH duration cell leaked raw ms (90000): $PATHB_ROW29" ;;
  *) pass_msg "per-PATH duration cell does not render raw ms (90000 absent)" ;;
esac

# (c) internal --emit-rows-json stays in raw ms (duration_ms == 90000).
ROWS29="$(bash "$HELPER" --fixture "$TMP29" --emit-rows-json 2>/dev/null)"
DMS29="$(printf '%s' "$ROWS29" | jq -r '.[] | select(.issue==231) | .duration_ms' 2>/dev/null)"
if [ "$DMS29" = "90000" ]; then
  pass_msg "--emit-rows-json duration_ms stays raw ms (90000), not minutes"
else
  fail_msg "--emit-rows-json duration_ms should stay 90000 (raw ms), got $DMS29"
fi
rm -rf "$TMP29"

# --- Scenario 32: inline-aware concurrency, honest lower-bound (#789 Task 5) ---
# The interval-overlap sweep STAYS headless-only (inline records are point-in-time
# ts_start==ts_end and can never overlap). emit_concurrency_assessment ADDS an
# inline-accounting line: keep the headless peak unchanged, COUNT inline records,
# and annotate the peak as a LOWER BOUND that excludes inline overlap.
# Fixture: issue 234 (PR #134), TWO overlapping headless execute records (peak 2)
# + ONE point-interval inline record (ts_start==ts_end, model="").
inc_scenario "Scenario 32: inline-aware concurrency (honest lower-bound) (#789)"

TMP32="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP32/" 2>/dev/null
printf '%s\n' '[
  {"number":134,"title":"feat: inline-aware concurrency","additions":300,"deletions":100,"body":"Closes #234","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP32/prs.json"
printf '%s\n' '{"number":134,"additions":300,"deletions":100,"comments":[]}' > "$TMP32/pr-134.json"
printf '%s\n' '{"number":234,"labels":[],"comments":[]}' > "$TMP32/issue-234.json"
{
  echo '{"schema_version":1,"issue":"234","stage":"execute","session_id":"h1","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K234A","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1800000,"ts_start":"2026-05-12T09:00:00Z","ts_end":"2026-05-12T09:30:00Z"}'
  echo '{"schema_version":1,"issue":"234","stage":"execute","session_id":"h2","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K234B","tokens":{"input":1000000,"output":0,"cache_read":0,"cache_creation":0,"total":1000000},"duration_ms":1800000,"ts_start":"2026-05-12T09:10:00Z","ts_end":"2026-05-12T09:40:00Z"}'
  echo '{"schema_version":1,"issue":"234","stage":"plan","session_id":"i1","model":"","agent_kind":"inline","record_key":"K234C","tokens":{"input":50000,"output":5000,"cache_read":0,"cache_creation":0,"total":55000},"duration_ms":1000,"ts_start":"2026-05-12T09:15:00Z","ts_end":"2026-05-12T09:15:00Z"}'
} > "$TMP32/capture.jsonl"

TOK32="$(bash "$HELPER" --fixture "$TMP32" --tokenomics 2>/dev/null)"
CONC_BLOCK32="$(printf '%s\n' "$TOK32" | awk '/CONCURRENCY/{f=1} f')"

# (a) headless interval peak is 2 — UNCHANGED by the inline point-interval record.
if printf '%s' "$CONC_BLOCK32" | grep -qE 'max observed concurrent execute workers: 2'; then
  pass_msg "headless interval peak == 2 (unchanged by inline record)"
else
  fail_msg "headless interval peak should be 2 (got: $CONC_BLOCK32)"
fi

# (b) the block carries a LOWER BOUND / not-interval-measurable annotation.
if printf '%s' "$CONC_BLOCK32" | grep -qiE 'lower bound'; then
  pass_msg "concurrency block annotates the peak as a LOWER BOUND"
else
  fail_msg "concurrency block should annotate the peak as a LOWER BOUND (got: $CONC_BLOCK32)"
fi
if printf '%s' "$CONC_BLOCK32" | grep -qiE 'not interval-measurable|point-in-time'; then
  pass_msg "concurrency block notes inline is point-in-time / not interval-measurable"
else
  fail_msg "concurrency block should note inline is point-in-time (got: $CONC_BLOCK32)"
fi

# (c) the ONE inline record is counted.
if printf '%s' "$CONC_BLOCK32" | grep -qE '1 inline record'; then
  pass_msg "concurrency block counts 1 inline record present"
else
  fail_msg "concurrency block should count 1 inline record (got: $CONC_BLOCK32)"
fi
rm -rf "$TMP32"

# --- Scenario 31: per-PATH token-bucket breakout (#789 Task 4) ---
# emit_path_table adds input|output|cache_creation|cache_read columns per N,
# sourced from CAPTURE_JSON (all records, per-issue bucket SUMS, medianed per PATH).
# Fixture: issue 233 (PR #133) PATH B, one execute record:
#   input 11000 output 22000 cache_creation 33000 cache_read 44000.
# Single-issue PATH → median == that issue's bucket sums.
inc_scenario "Scenario 31: per-PATH token-bucket breakout (#789)"

TMP31="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP31/" 2>/dev/null
printf '%s\n' '[
  {"number":133,"title":"feat: path bucket breakout","additions":300,"deletions":100,"body":"Closes #233","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP31/prs.json"
printf '%s\n' '{"number":133,"additions":300,"deletions":100,"comments":[]}' > "$TMP31/pr-133.json"
printf '%s\n' '{"number":233,"labels":[],"comments":[]}' > "$TMP31/issue-233.json"
{
  echo '{"schema_version":1,"issue":"233","stage":"execute","session_id":"s31","model":"claude-opus-4-8","agent_kind":"headless","record_key":"K233","tokens":{"input":11000,"output":22000,"cache_creation":33000,"cache_read":44000,"total":110000},"duration_ms":1000}'
} > "$TMP31/capture.jsonl"

TABLE31="$(bash "$HELPER" --fixture "$TMP31" 2>/dev/null)"

# (a) per-PATH header carries the four bucket columns.
PATH_HDR31="$(printf '%s\n' "$TABLE31" | grep -E '^PATH \| N')"
for col in input output cache_creation cache_read; do
  case "$PATH_HDR31" in
    *"$col"*) pass_msg "per-PATH header carries '$col' column" ;;
    *) fail_msg "per-PATH header missing '$col' column (got: $PATH_HDR31)" ;;
  esac
done

# (b) the B row shows the per-PATH bucket medians.
# Row shape: PATH | N | median loc | median tokens | median dur(min) | median tokens/loc | median ms/loc | input | output | cache_creation | cache_read
PATHB_ROW31="$(printf '%s\n' "$TABLE31" | grep -E '^B[[:space:]]*\|' | head -1)"
P_IN31="$(printf '%s' "$PATHB_ROW31" | awk -F'|' '{gsub(/[ ]/,"",$8); print $8}')"
P_OUT31="$(printf '%s' "$PATHB_ROW31" | awk -F'|' '{gsub(/[ ]/,"",$9); print $9}')"
P_CC31="$(printf '%s' "$PATHB_ROW31" | awk -F'|' '{gsub(/[ ]/,"",$10); print $10}')"
P_CR31="$(printf '%s' "$PATHB_ROW31" | awk -F'|' '{gsub(/[ ]/,"",$11); print $11}')"
if [ "$P_IN31" = "11000" ]; then pass_msg "per-PATH B input bucket == 11000"; else fail_msg "per-PATH B input should be 11000, got $P_IN31 (row=$PATHB_ROW31)"; fi
if [ "$P_OUT31" = "22000" ]; then pass_msg "per-PATH B output bucket == 22000"; else fail_msg "per-PATH B output should be 22000, got $P_OUT31 (row=$PATHB_ROW31)"; fi
if [ "$P_CC31" = "33000" ]; then pass_msg "per-PATH B cache_creation bucket == 33000"; else fail_msg "per-PATH B cache_creation should be 33000, got $P_CC31 (row=$PATHB_ROW31)"; fi
if [ "$P_CR31" = "44000" ]; then pass_msg "per-PATH B cache_read bucket == 44000"; else fail_msg "per-PATH B cache_read should be 44000, got $P_CR31 (row=$PATHB_ROW31)"; fi
rm -rf "$TMP31"

# --- Scenario 30: per-stage token-bucket breakout, unpriced-honest (#789 Task 2) ---
# emit_stage_table adds input|output|cache_creation|cache_read columns per N,
# sourced from CAPTURE_JSON (ALL records, priced + unpriced) so an UNPRICED
# (model="") stage shows REAL token counts, not zero.
# Fixture: issue 232 (PR #132), one UNPRICED inline execute record:
#   input 111000 output 222000 cache_creation 333000 cache_read 444000.
inc_scenario "Scenario 30: per-stage token-bucket breakout (unpriced-honest) (#789)"

TMP30="$(mktemp -d)"
cp "$FIXTURE_DIR"/*.json "$TMP30/" 2>/dev/null
printf '%s\n' '[
  {"number":132,"title":"feat: stage bucket breakout","additions":300,"deletions":100,"body":"Closes #232","mergedAt":"2026-05-13T12:00:00Z","labels":[]}
]' > "$TMP30/prs.json"
printf '%s\n' '{"number":132,"additions":300,"deletions":100,"comments":[]}' > "$TMP30/pr-132.json"
printf '%s\n' '{"number":232,"labels":[],"comments":[]}' > "$TMP30/issue-232.json"
{
  echo '{"schema_version":1,"issue":"232","stage":"execute","session_id":"s30","model":"","agent_kind":"inline","record_key":"K232","tokens":{"input":111000,"output":222000,"cache_creation":333000,"cache_read":444000,"total":1110000},"duration_ms":1000}'
} > "$TMP30/capture.jsonl"

TABLE30="$(bash "$HELPER" --fixture "$TMP30" 2>/dev/null)"

# (a) per-stage header carries the four bucket columns.
STAGE_HDR30="$(printf '%s\n' "$TABLE30" | grep -E '^STAGE \| N')"
for col in input output cache_creation cache_read; do
  case "$STAGE_HDR30" in
    *"$col"*) pass_msg "per-stage header carries '$col' column" ;;
    *) fail_msg "per-stage header missing '$col' column (got: $STAGE_HDR30)" ;;
  esac
done

# (b) the execute row (UNPRICED) shows REAL per-bucket medians, not zero.
# Row shape: STAGE | N | median tokens | median dur(min) | input | output | cache_creation | cache_read
EXEC_ROW30="$(printf '%s\n' "$TABLE30" | grep -E '^execute[[:space:]]*\|' | head -1)"
E_IN30="$(printf '%s' "$EXEC_ROW30" | awk -F'|' '{gsub(/[ ]/,"",$5); print $5}')"
E_OUT30="$(printf '%s' "$EXEC_ROW30" | awk -F'|' '{gsub(/[ ]/,"",$6); print $6}')"
E_CC30="$(printf '%s' "$EXEC_ROW30" | awk -F'|' '{gsub(/[ ]/,"",$7); print $7}')"
E_CR30="$(printf '%s' "$EXEC_ROW30" | awk -F'|' '{gsub(/[ ]/,"",$8); print $8}')"
if [ "$E_IN30" = "111000" ]; then pass_msg "execute input bucket == 111000 (unpriced shown)"; else fail_msg "execute input should be 111000, got $E_IN30 (row=$EXEC_ROW30)"; fi
if [ "$E_OUT30" = "222000" ]; then pass_msg "execute output bucket == 222000"; else fail_msg "execute output should be 222000, got $E_OUT30 (row=$EXEC_ROW30)"; fi
if [ "$E_CC30" = "333000" ]; then pass_msg "execute cache_creation bucket == 333000"; else fail_msg "execute cache_creation should be 333000, got $E_CC30 (row=$EXEC_ROW30)"; fi
if [ "$E_CR30" = "444000" ]; then pass_msg "execute cache_read bucket == 444000"; else fail_msg "execute cache_read should be 444000, got $E_CR30 (row=$EXEC_ROW30)"; fi
rm -rf "$TMP30"

# --- Scenario 33: reconciled substrate drops usage_complete:false (#816 Task 1) ---
# Cost/token magnitude tables aggregate the reconciled substrate (usage_complete
# != false). A standalone usage_complete:false lower-bound on a DISTINCT
# session_id survives both dedup passes but must be EXCLUDED from the magnitude.
inc_scenario "Scenario 33: reconciled-substrate drop of usage_complete:false (#816)"

TMP33="$(mktemp -d)"; cp "$FIXTURE_DIR"/*.json "$TMP33/" 2>/dev/null
printf '%s\n' '[{"number":133,"title":"feat: reconciled substrate","additions":10,"deletions":0,"body":"Closes #233","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP33/prs.json"
printf '%s\n' '{"number":133,"additions":10,"deletions":0,"comments":[]}' > "$TMP33/pr-133.json"
printf '%s\n' '{"number":233,"labels":[],"comments":[]}' > "$TMP33/issue-233.json"
{ echo '{"schema_version":1,"issue":"233","stage":"execute","session_id":"s33t","model":"claude-opus-4-8","agent_kind":"inline","source":"retroactive","usage_complete":true,"record_key":"K233T","tokens":{"input":1000,"output":1000,"cache_creation":1000,"cache_read":1000,"total":4000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"233","stage":"execute","session_id":"s33f","model":"claude-opus-4-8","agent_kind":"inline","source":"forward","usage_complete":false,"record_key":"K233F","tokens":{"input":50,"output":50,"cache_creation":50,"cache_read":50,"total":200},"duration_ms":1000}'
} > "$TMP33/capture.jsonl"
ROWS33="$(bash "$HELPER" --fixture "$TMP33" --emit-rows-json 2>/dev/null)"
TT33="$(printf '%s' "$ROWS33" | jq -r '.[] | select(.issue==233) | .tokens_total')"
if [ "$TT33" = "4000" ]; then pass_msg "issue 233 cost-table tokens exclude usage_complete:false lower-bound (4200 rejected)"; else fail_msg "issue 233 tokens_total should be 4000 (true only), got $TT33"; fi
rm -rf "$TMP33"

# --- Scenario 34: coverage-health full-stream count + excluded disclosure (#816 Task 2) ---
# Coverage-health reads the FULL deduped stream (CAPTURE_ALL) so the lower-bound
# count is the TRUE total (regression guard against shrinking to the reconciled
# stream); a NEW line discloses how many lower-bounds were EXCLUDED from cost tables.
inc_scenario "Scenario 34: coverage-health full-stream + excluded disclosure (#816)"

TMP34="$(mktemp -d)"; cp "$FIXTURE_DIR"/*.json "$TMP34/" 2>/dev/null
printf '%s\n' '[{"number":134,"title":"feat: coverage disclosure","additions":10,"deletions":0,"body":"Closes #234","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP34/prs.json"
printf '%s\n' '{"number":134,"additions":10,"deletions":0,"comments":[]}' > "$TMP34/pr-134.json"
printf '%s\n' '{"number":234,"labels":[],"comments":[]}' > "$TMP34/issue-234.json"
{ echo '{"schema_version":1,"issue":"234","stage":"execute","session_id":"s34t","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K234T","tokens":{"input":10,"output":10,"cache_creation":10,"cache_read":10,"total":40},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"234","stage":"execute","session_id":"s34f","model":"","agent_kind":"inline","usage_complete":false,"record_key":"K234F","tokens":{"input":5,"output":5,"cache_read":5,"cache_creation":5,"total":20},"duration_ms":900}'
} > "$TMP34/capture.jsonl"
TOK34="$(bash "$HELPER" --fixture "$TMP34" --tokenomics 2>/dev/null)"
COV34="$(printf '%s\n' "$TOK34" | awk '/COVERAGE/{f=1} f')"
LB34="$(printf '%s\n' "$COV34" | grep -iE 'lower-bound \(unreconciled\)' | head -1)"
case "$LB34" in *1/2*) pass_msg "coverage lower-bound count still over FULL stream (1/2)";; *) fail_msg "coverage lower-bound should be 1/2, got: $LB34";; esac
EXC34="$(printf '%s\n' "$COV34" | grep -iE 'excluded.*cost tables' | head -1)"
case "$EXC34" in *1*) pass_msg "coverage discloses excluded-from-cost-tables count (1)";; *) fail_msg "coverage missing excluded-from-cost-tables disclosure, got: $EXC34";; esac
rm -rf "$TMP34"

# --- Scenario 35: --since DATE filters by ts_start (#816 Task 3) ---
inc_scenario "Scenario 35: --since DATE scopes cost tables to the reconcilable era (#816)"

TMP35="$(mktemp -d)"; cp "$FIXTURE_DIR"/*.json "$TMP35/" 2>/dev/null
printf '%s\n' '[{"number":135,"title":"feat: since filter","additions":10,"deletions":0,"body":"Closes #235","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP35/prs.json"
printf '%s\n' '{"number":135,"additions":10,"deletions":0,"comments":[]}' > "$TMP35/pr-135.json"
printf '%s\n' '{"number":235,"labels":[],"comments":[]}' > "$TMP35/issue-235.json"
{ echo '{"schema_version":1,"issue":"235","stage":"execute","session_id":"s35a","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K235A","ts_start":"2026-05-20T10:00:00Z","tokens":{"input":1000,"output":0,"cache_creation":0,"cache_read":0,"total":1000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"235","stage":"execute","session_id":"s35b","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K235B","ts_start":"2026-05-31T10:00:00Z","tokens":{"input":2000,"output":0,"cache_creation":0,"cache_read":0,"total":2000},"duration_ms":1000}'
} > "$TMP35/capture.jsonl"
ALL35="$(bash "$HELPER" --fixture "$TMP35" --emit-rows-json 2>/dev/null | jq -r '.[] | select(.issue==235) | .tokens_total')"
SIN35="$(bash "$HELPER" --fixture "$TMP35" --since 2026-05-31 --emit-rows-json 2>/dev/null | jq -r '.[] | select(.issue==235) | .tokens_total')"
if [ "$ALL35" = "3000" ]; then pass_msg "no --since aggregates both dates (3000)"; else fail_msg "expected 3000 without --since, got $ALL35"; fi
if [ "$SIN35" = "2000" ]; then pass_msg "--since 2026-05-31 keeps only on/after-cutoff record (2000)"; else fail_msg "expected 2000 with --since 2026-05-31, got $SIN35"; fi
rm -rf "$TMP35"

# --- Scenario 36: absent-usage_complete records stay in cost tables (#816 Task 4) ---
# Fixture/legacy compat: a record with NO usage_complete field must still be
# aggregated (the != false predicate keeps it; codifies the contract so a later
# switch to == true would break loudly).
inc_scenario "Scenario 36: absent usage_complete record kept (fixture-compat) (#816)"

TMP36="$(mktemp -d)"; cp "$FIXTURE_DIR"/*.json "$TMP36/" 2>/dev/null
printf '%s\n' '[{"number":136,"title":"feat: absent-field compat","additions":10,"deletions":0,"body":"Closes #236","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP36/prs.json"
printf '%s\n' '{"number":136,"additions":10,"deletions":0,"comments":[]}' > "$TMP36/pr-136.json"
printf '%s\n' '{"number":236,"labels":[],"comments":[]}' > "$TMP36/issue-236.json"
echo '{"schema_version":1,"issue":"236","stage":"execute","session_id":"s36","model":"claude-opus-4-8","agent_kind":"inline","record_key":"K236","tokens":{"input":7000,"output":0,"cache_creation":0,"cache_read":0,"total":7000},"duration_ms":1000}' > "$TMP36/capture.jsonl"
TT36="$(bash "$HELPER" --fixture "$TMP36" --emit-rows-json 2>/dev/null | jq -r '.[] | select(.issue==236) | .tokens_total')"
if [ "$TT36" = "7000" ]; then pass_msg "record with absent usage_complete is kept (7000)"; else fail_msg "absent usage_complete record should be kept (7000), got $TT36"; fi
rm -rf "$TMP36"

# --- Scenario 37: concurrency inline_n counts the FULL stream (#816 evaluator item 1) ---
# emit_concurrency_assessment's "N inline records present" is a PRESENCE
# disclosure, not a cost magnitude — it must read CAPTURE_ALL so explicit-false
# inline lower-bounds are not silently dropped from the count.
inc_scenario "Scenario 37: concurrency inline_n reads full stream (#816)"

TMP37="$(mktemp -d)"; cp "$FIXTURE_DIR"/*.json "$TMP37/" 2>/dev/null
printf '%s\n' '[{"number":137,"title":"feat: inline_n full stream","additions":10,"deletions":0,"body":"Closes #237","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP37/prs.json"
printf '%s\n' '{"number":137,"additions":10,"deletions":0,"comments":[]}' > "$TMP37/pr-137.json"
printf '%s\n' '{"number":237,"labels":[],"comments":[]}' > "$TMP37/issue-237.json"
{ echo '{"schema_version":1,"issue":"237","stage":"execute","session_id":"s37t","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K237T","tokens":{"input":10,"output":10,"cache_creation":10,"cache_read":10,"total":40},"duration_ms":1000,"ts_start":"2026-05-31T09:00:00Z","ts_end":"2026-05-31T09:00:00Z"}'
  echo '{"schema_version":1,"issue":"237","stage":"execute","session_id":"s37f","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":false,"record_key":"K237F","tokens":{"input":5,"output":5,"cache_creation":5,"cache_read":5,"total":20},"duration_ms":900,"ts_start":"2026-05-31T09:05:00Z","ts_end":"2026-05-31T09:05:00Z"}'
} > "$TMP37/capture.jsonl"
TOK37="$(bash "$HELPER" --fixture "$TMP37" --tokenomics 2>/dev/null)"
CONC37="$(printf '%s\n' "$TOK37" | awk '/CONCURRENCY/{f=1} f')"
IL37="$(printf '%s\n' "$CONC37" | grep -iE 'inline record' | head -1)"
case "$IL37" in *"2 inline record"*) pass_msg "concurrency inline_n counts full stream (2, incl usage_complete:false)";; *) fail_msg "concurrency inline_n should count 2 (full stream), got: $IL37";; esac
rm -rf "$TMP37"

# --- Scenario 38: --until DATE upper-bounds by ts_start (#831) ---
inc_scenario "Scenario 38: --until DATE upper-bounds cost tables by ts_start (#831)"
TMP38="$(mktemp -d)"; cp "$FIXTURE_DIR"/*.json "$TMP38/" 2>/dev/null
printf '%s\n' '[{"number":138,"title":"feat: until filter","additions":10,"deletions":0,"body":"Closes #238","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP38/prs.json"
printf '%s\n' '{"number":138,"additions":10,"deletions":0,"comments":[]}' > "$TMP38/pr-138.json"
printf '%s\n' '{"number":238,"labels":[],"comments":[]}' > "$TMP38/issue-238.json"
{ echo '{"schema_version":1,"issue":"238","stage":"execute","session_id":"s38a","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K238A","ts_start":"2026-05-20T10:00:00Z","tokens":{"input":1000,"output":0,"cache_creation":0,"cache_read":0,"total":1000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"238","stage":"execute","session_id":"s38b","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K238B","ts_start":"2026-05-31T10:00:00Z","tokens":{"input":2000,"output":0,"cache_creation":0,"cache_read":0,"total":2000},"duration_ms":1000}'
} > "$TMP38/capture.jsonl"
ALL38="$(bash "$HELPER" --fixture "$TMP38" --emit-rows-json 2>/dev/null | jq -r '.[] | select(.issue==238) | .tokens_total')"
UNT38="$(bash "$HELPER" --fixture "$TMP38" --until 2026-05-20 --emit-rows-json 2>/dev/null | jq -r '.[] | select(.issue==238) | .tokens_total')"
if [ "$ALL38" = "3000" ]; then pass_msg "no --until aggregates both dates (3000)"; else fail_msg "expected 3000 without --until, got $ALL38"; fi
if [ "$UNT38" = "1000" ]; then pass_msg "--until 2026-05-20 keeps only on/before-cutoff record (1000, inclusive)"; else fail_msg "expected 1000 with --until 2026-05-20, got $UNT38"; fi
rm -rf "$TMP38"

# --- Scenario 39: --since + --until form a closed window; empty ts_start excluded (#831) ---
inc_scenario "Scenario 39: --since+--until closed window + empty-ts_start excluded under --until (#831)"
TMP39="$(mktemp -d)"; cp "$FIXTURE_DIR"/*.json "$TMP39/" 2>/dev/null
printf '%s\n' '[{"number":139,"title":"feat: closed window","additions":10,"deletions":0,"body":"Closes #239","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP39/prs.json"
printf '%s\n' '{"number":139,"additions":10,"deletions":0,"comments":[]}' > "$TMP39/pr-139.json"
printf '%s\n' '{"number":239,"labels":[],"comments":[]}' > "$TMP39/issue-239.json"
{ echo '{"schema_version":1,"issue":"239","stage":"execute","session_id":"s39a","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K239A","ts_start":"2026-05-19T10:00:00Z","tokens":{"input":100,"output":0,"cache_creation":0,"cache_read":0,"total":100},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"239","stage":"execute","session_id":"s39b","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K239B","ts_start":"2026-05-20T10:00:00Z","tokens":{"input":2000,"output":0,"cache_creation":0,"cache_read":0,"total":2000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"239","stage":"execute","session_id":"s39c","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K239C","ts_start":"2026-05-25T10:00:00Z","tokens":{"input":400,"output":0,"cache_creation":0,"cache_read":0,"total":400},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"239","stage":"execute","session_id":"s39e","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K239E","ts_start":"","tokens":{"input":9999,"output":0,"cache_creation":0,"cache_read":0,"total":9999},"duration_ms":1000}'
} > "$TMP39/capture.jsonl"
WIN39="$(bash "$HELPER" --fixture "$TMP39" --since 2026-05-20 --until 2026-05-20 --emit-rows-json 2>/dev/null | jq -r '.[] | select(.issue==239) | .tokens_total')"
if [ "$WIN39" = "2000" ]; then pass_msg "--since 2026-05-20 --until 2026-05-20 isolates a single day (2000), excludes 05-19/05-25 and empty ts_start (9999)"; else fail_msg "expected 2000 for closed single-day window, got $WIN39"; fi
rm -rf "$TMP39"

# --- Scenario 40: --per-day emits one day-block per day in the window (#831) ---
inc_scenario "Scenario 40: --per-day emits N day-blocks for an N-day window (#831)"
TMP40="$(mktemp -d)"; cp "$FIXTURE_DIR"/*.json "$TMP40/" 2>/dev/null
printf '%s\n' '[{"number":140,"title":"feat: per-day","additions":10,"deletions":0,"body":"Closes #240","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP40/prs.json"
printf '%s\n' '{"number":140,"additions":10,"deletions":0,"comments":[]}' > "$TMP40/pr-140.json"
printf '%s\n' '{"number":240,"labels":[],"comments":[]}' > "$TMP40/issue-240.json"
{ echo '{"schema_version":1,"issue":"240","stage":"execute","session_id":"s40a","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K240A","ts_start":"2026-05-20T10:00:00Z","tokens":{"input":1000,"output":0,"cache_creation":0,"cache_read":0,"total":1000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"240","stage":"execute","session_id":"s40c","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K240C","ts_start":"2026-05-22T10:00:00Z","tokens":{"input":3000,"output":0,"cache_creation":0,"cache_read":0,"total":3000},"duration_ms":1000}'
} > "$TMP40/capture.jsonl"
PD40="$(bash "$HELPER" --fixture "$TMP40" --per-day --since 2026-05-20 --until 2026-05-22 2>/dev/null)"
DAYHDRS40="$(printf '%s\n' "$PD40" | grep -cE '^=== DAY 2026-05-2[0-2] ===$')"
if [ "$DAYHDRS40" = "3" ]; then pass_msg "--per-day emits 3 day-blocks for a 3-day window (05-20..05-22)"; else fail_msg "expected 3 day-block headers, got $DAYHDRS40"; fi
if printf '%s\n' "$PD40" | grep -qE '^=== DAY 2026-05-20 ===$' \
   && printf '%s\n' "$PD40" | grep -qE '^=== DAY 2026-05-21 ===$' \
   && printf '%s\n' "$PD40" | grep -qE '^=== DAY 2026-05-22 ===$'; then
  pass_msg "--per-day day headers cover each day in [since,until] inclusive"
else
  fail_msg "--per-day missing one of the expected day headers"
fi
rm -rf "$TMP40"

# --- Scenario 41: unknown-arg guard intact + --help documents new flags (#831) ---
inc_scenario "Scenario 41: unknown-arg guard intact + --help documents --until/--per-day (#831)"
bash "$HELPER" --bogus-flag >/dev/null 2>&1
if [ "$?" -ne 0 ]; then pass_msg "unknown arg --bogus-flag still exits non-zero"; else fail_msg "unknown arg should exit non-zero (guard regressed)"; fi
HELP41="$(bash "$HELPER" --help 2>&1 || true)"
if printf '%s' "$HELP41" | grep -q -- '--until'; then pass_msg "--help documents --until"; else fail_msg "--help missing --until"; fi
if printf '%s' "$HELP41" | grep -q -- '--per-day'; then pass_msg "--help documents --per-day"; else fail_msg "--help missing --per-day"; fi

# --- Scenario 42: --emit-day-json per-day aggregate mode (#832) ---
# Builds a 2-day fixture window. Day 2026-05-31 has two PRICED opus records
# (input-only + output-only) plus one UNPRICED (model:"") record; Day
# 2026-06-01 has one PRICED opus record plus one explicit usage_complete:false
# lower-bound (excluded from totals but flips the floor flag). Issue 250 is the
# in-window LOC join (PR 150, loc 10).
inc_scenario "Scenario 42: --emit-day-json per-day aggregates (#832)"
TMP42="$(mktemp -d)"
printf '%s\n' '[{"number":150,"title":"feat: day-json","additions":7,"deletions":3,"body":"Closes #250","mergedAt":"2026-05-31T12:00:00Z","labels":[]}]' > "$TMP42/prs.json"
printf '%s\n' '{"number":150,"additions":7,"deletions":3,"comments":[]}' > "$TMP42/pr-150.json"
printf '%s\n' '{"number":250,"labels":[],"comments":[]}' > "$TMP42/issue-250.json"
{ echo '{"schema_version":1,"issue":"250","stage":"plan","session_id":"s42a","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K42A","ts_start":"2026-05-31T09:00:00Z","tokens":{"input":1000,"output":0,"cache_creation":0,"cache_read":0,"total":1000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"250","stage":"execute","session_id":"s42b","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K42B","ts_start":"2026-05-31T10:00:00Z","tokens":{"input":0,"output":2000,"cache_creation":0,"cache_read":0,"total":2000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"250","stage":"pr-eval","session_id":"s42c","model":"","agent_kind":"inline","usage_complete":true,"record_key":"K42C","ts_start":"2026-05-31T11:00:00Z","tokens":{"input":500,"output":0,"cache_creation":0,"cache_read":0,"total":500},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"250","stage":"execute","session_id":"s42d","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":true,"record_key":"K42D","ts_start":"2026-06-01T10:00:00Z","tokens":{"input":4000,"output":0,"cache_creation":0,"cache_read":0,"total":4000},"duration_ms":1000}'
  echo '{"schema_version":1,"issue":"250","stage":"execute","session_id":"s42e","model":"claude-opus-4-8","agent_kind":"inline","usage_complete":false,"record_key":"K42E","ts_start":"2026-06-01T11:00:00Z","tokens":{"input":9999,"output":0,"cache_creation":0,"cache_read":0,"total":9999},"duration_ms":1000}'
} > "$TMP42/capture.jsonl"

DJ42="$(bash "$HELPER" --fixture "$TMP42" --emit-day-json --since 2026-05-31 --until 2026-06-01 2>/dev/null)"
DJ42_RC=$?
if [ "$DJ42_RC" -eq 0 ]; then pass_msg "--emit-day-json exits 0"; else fail_msg "--emit-day-json exited non-zero (rc=$DJ42_RC)"; fi

if printf '%s' "$DJ42" | jq -se 'length==2' >/dev/null 2>&1; then
  pass_msg "--emit-day-json emits valid JSON Lines, 2 day objects"
else
  fail_msg "--emit-day-json expected 2 JSON-Lines day objects (got: $(printf '%s' "$DJ42" | head -3))"
fi

# Schema-key presence on the first day object.
KEYS42="$(printf '%s' "$DJ42" | head -1 | jq -r '[paths(scalars==null or true)] | length' 2>/dev/null)"
if printf '%s' "$DJ42" | head -1 | jq -e '
    has("date") and has("n") and (.tokens|has("input") and has("output") and has("cache_creation") and has("cache_read") and has("total"))
    and (.per_n|has("input") and has("output") and has("cache_creation") and has("cache_read") and has("total"))
    and has("active_loc") and has("per_loc")
    and has("priced_n")
    and (.cost|has("input") and has("output") and has("cache_creation") and has("cache_read") and has("total"))
    and has("cost_per_n") and has("cost_per_loc") and has("usage_complete_floor")' >/dev/null 2>&1; then
  pass_msg "day object carries the full schema keys"
else
  fail_msg "day object missing schema keys (got: $(printf '%s' "$DJ42" | head -1))"
fi

dj_field() { printf '%s' "$DJ42" | jq -r --arg d "$1" 'select(.date==$d) | '"$2" 2>/dev/null; }

# Day 2026-05-31: 3 records (2 priced + 1 unpriced); tokens.total=1000+2000+500=3500; priced_n=2.
if [ "$(dj_field 2026-05-31 '.n')" = "3" ]; then pass_msg "05-31 n==3 (all records incl. unpriced)"; else fail_msg "05-31 n expected 3, got $(dj_field 2026-05-31 '.n')"; fi
if [ "$(dj_field 2026-05-31 '.tokens.total')" = "3500" ]; then pass_msg "05-31 tokens.total==3500"; else fail_msg "05-31 tokens.total expected 3500, got $(dj_field 2026-05-31 '.tokens.total')"; fi
# tokens.input sums ALL records (priced + unpriced): 1000 (K42A) + 500 (K42C unpriced) = 1500.
if [ "$(dj_field 2026-05-31 '.tokens.input')" = "1500" ]; then pass_msg "05-31 tokens.input==1500 (incl. unpriced)"; else fail_msg "05-31 tokens.input expected 1500, got $(dj_field 2026-05-31 '.tokens.input')"; fi
if [ "$(dj_field 2026-05-31 '.tokens.output')" = "2000" ]; then pass_msg "05-31 tokens.output==2000"; else fail_msg "05-31 tokens.output expected 2000, got $(dj_field 2026-05-31 '.tokens.output')"; fi
if [ "$(dj_field 2026-05-31 '.priced_n')" = "2" ]; then pass_msg "05-31 priced_n==2 (excludes model:\"\")"; else fail_msg "05-31 priced_n expected 2, got $(dj_field 2026-05-31 '.priced_n')"; fi
if [ "$(dj_field 2026-05-31 '.usage_complete_floor')" = "false" ]; then pass_msg "05-31 usage_complete_floor==false (clean day)"; else fail_msg "05-31 floor expected false, got $(dj_field 2026-05-31 '.usage_complete_floor')"; fi
# cost.total = 1000/1e6*15 + 2000/1e6*75 = 0.015 + 0.15 = 0.165
if awk -v c="$(dj_field 2026-05-31 '.cost.total')" 'BEGIN{exit !(c>0.16 && c<0.17)}'; then pass_msg "05-31 cost.total ~= 0.165"; else fail_msg "05-31 cost.total expected ~0.165, got $(dj_field 2026-05-31 '.cost.total')"; fi
# active_loc: issue 250 has records on 05-31, loc=10 → active_loc=10
if [ "$(dj_field 2026-05-31 '.active_loc')" = "10" ]; then pass_msg "05-31 active_loc==10 (issue 250 LOC join)"; else fail_msg "05-31 active_loc expected 10, got $(dj_field 2026-05-31 '.active_loc')"; fi

# Day 2026-06-01: usage_complete:false record excluded from totals (4000 only); floor flips true.
if [ "$(dj_field 2026-06-01 '.n')" = "1" ]; then pass_msg "06-01 n==1 (lower-bound excluded from substrate)"; else fail_msg "06-01 n expected 1, got $(dj_field 2026-06-01 '.n')"; fi
if [ "$(dj_field 2026-06-01 '.tokens.total')" = "4000" ]; then pass_msg "06-01 tokens.total==4000 (lower-bound excluded)"; else fail_msg "06-01 tokens.total expected 4000, got $(dj_field 2026-06-01 '.tokens.total')"; fi
if [ "$(dj_field 2026-06-01 '.usage_complete_floor')" = "true" ]; then pass_msg "06-01 usage_complete_floor==true (day still has a lower-bound)"; else fail_msg "06-01 floor expected true, got $(dj_field 2026-06-01 '.usage_complete_floor')"; fi
rm -rf "$TMP42"

# --- Scenario 43: --history renders the persisted store, no gh (#832) ---
inc_scenario "Scenario 43: --history render mode (#832)"
TMP43="$(mktemp -d)"
STORE43="$TMP43/tokenomics-history.jsonl"
{ echo '{"date":"2026-05-30","n":4,"tokens":{"input":100,"output":50,"cache_creation":0,"cache_read":200,"total":350},"per_n":{"input":25,"output":12.5,"cache_creation":0,"cache_read":50,"total":87.5},"active_loc":40,"per_loc":{"input":2.5,"output":1.25,"cache_creation":0,"cache_read":5,"total":8.75},"priced_n":4,"cost":{"input":0.0015,"output":0.00375,"cache_creation":0,"cache_read":0.0003,"total":0.00555},"cost_per_n":0.0013875,"cost_per_loc":0.000138,"usage_complete_floor":false}'
  echo '{"date":"2026-05-31","n":2,"tokens":{"input":1000,"output":2000,"cache_creation":0,"cache_read":0,"total":3000},"per_n":{"input":500,"output":1000,"cache_creation":0,"cache_read":0,"total":1500},"active_loc":null,"per_loc":null,"priced_n":2,"cost":{"input":0.015,"output":0.15,"cache_creation":0,"cache_read":0,"total":0.165},"cost_per_n":0.0825,"cost_per_loc":null,"usage_complete_floor":true}'
} > "$STORE43"
HIST43="$(bash "$HELPER" --history "$STORE43" 2>/dev/null)"
HIST43_RC=$?
if [ "$HIST43_RC" -eq 0 ]; then pass_msg "--history exits 0"; else fail_msg "--history exited non-zero (rc=$HIST43_RC)"; fi
if printf '%s' "$HIST43" | grep -qi 'HISTORY (persisted per-day)'; then pass_msg "--history prints the HISTORY table header"; else fail_msg "--history missing HISTORY header"; fi
if printf '%s' "$HIST43" | grep -q '2026-05-30' && printf '%s' "$HIST43" | grep -q '2026-05-31'; then pass_msg "--history renders one row per stored day"; else fail_msg "--history missing a stored day row"; fi
# null per_loc / cost_per_loc render as --
if printf '%s' "$HIST43" | grep -E '2026-05-31' | grep -q -- '--'; then pass_msg "--history renders null per-LOC as --"; else fail_msg "--history did not render null per-LOC as --"; fi
# Absent store → graceful empty notice, exit 0, no gh.
HIST43B="$(bash "$HELPER" --history "$TMP43/does-not-exist.jsonl" 2>/dev/null)"
HIST43B_RC=$?
if [ "$HIST43B_RC" -eq 0 ]; then pass_msg "--history absent store exits 0 (graceful)"; else fail_msg "--history absent store exited non-zero (rc=$HIST43B_RC)"; fi
if printf '%s' "$HIST43B" | grep -qi 'no persisted store'; then pass_msg "--history absent store prints empty notice"; else fail_msg "--history absent store missing empty notice (got: $HIST43B)"; fi
rm -rf "$TMP43"

# --- Scenario 44: --help documents --emit-day-json + --history (#832) ---
inc_scenario "Scenario 44: --help documents --emit-day-json + --history (#832)"
HELP44="$(bash "$HELPER" --help 2>&1 || true)"
if printf '%s' "$HELP44" | grep -q -- '--emit-day-json'; then pass_msg "--help documents --emit-day-json"; else fail_msg "--help missing --emit-day-json"; fi
if printf '%s' "$HELP44" | grep -q -- '--history'; then pass_msg "--help documents --history"; else fail_msg "--help missing --history"; fi

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
