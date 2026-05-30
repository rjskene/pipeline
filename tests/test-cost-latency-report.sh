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

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
