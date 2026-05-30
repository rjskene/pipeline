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

TT8="$(printf '%s' "$ROWS8" | jq -r '.[] | select(.issue==202) | .tokens_total' 2>/dev/null)"
if [ "$TT8" = "32500" ]; then
  pass_msg "valid capture records still summed despite one malformed line (202=32500)"
else
  fail_msg "expected issue 202 tokens_total=32500 with a malformed line present, got $TT8"
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
#   sess-A: 1000 + 3000 = 4000   sess-B: 2000
# → N must be 2 (two session groups); median of per-session SUMS (4000, 2000) = 3000.
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

# Median tokens cell == median of per-session sums (4000, 2000) == 3000.
ORCH_TOK12="$(printf '%s' "$ORCH_ROW12" | awk -F'|' '{gsub(/ /,"",$3); print $3}')"
if [ "$ORCH_TOK12" = "3000" ]; then
  pass_msg "orchestrator median tokens == 3000 (median of per-session sums)"
else
  fail_msg "orchestrator median tokens should be 3000 (median of per-session sums), got $ORCH_TOK12 (row: $ORCH_ROW12)"
fi

# Must NOT be the grand all-time sum.
case "$ORCH_ROW12" in
  *6000*) fail_msg "orchestrator row leaked grand all-time sum 6000 (row: $ORCH_ROW12)" ;;
  *) pass_msg "orchestrator row does not render grand all-time sum 6000" ;;
esac
rm -rf "$TMP12"

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
