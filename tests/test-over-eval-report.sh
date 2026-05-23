#!/bin/bash
set -uo pipefail
#
# Tests for scripts/over-eval-report.sh — dogfood-only one-off measurement
# (issue #419). Walks the last N merged PRs and emits a per-PATH summary
# table comparing PR diff size against plan / plan-eval / pr-eval verbosity.
#
# Uses fixture mode (--fixture <dir>) so no live `gh` calls are required.
# The fixture directory must contain:
#   - prs.json           — synthetic `gh pr list ... --json number,title,...` payload
#   - pr-<N>.json        — synthetic `gh pr view <N> --json ...` payload (one per PR)
#   - issue-<N>.json     — synthetic `gh issue view <N> --json ...` payload (one per linked issue)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/over-eval-report.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/over-eval-report"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

inc_scenario() { echo ""; echo "-- $1 --"; }

# --- Scenario 1: scaffolding (script existence + shebang + --help banner) ---
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/over-eval-report.sh"
else
  fail_msg "script file missing at scripts/over-eval-report.sh"
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
fi

# --- Scenario 2: fixture loader iterates PRs ---
# Uses the static fixture directory tests/fixtures/over-eval-report which
# carries five synthetic PRs (one per PATH plus an outlier in PATH B).
inc_scenario "Scenario 2: fixture loader walks all PRs in tests/fixtures/over-eval-report"

ROWS_OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-rows-json 2>/dev/null || true)"
ROWS_RC=$?
if [ "$ROWS_RC" -eq 0 ]; then
  pass_msg "fixture-mode run exits 0"
else
  fail_msg "fixture-mode run exited non-zero (rc=$ROWS_RC)"
fi

EXPECTED_FIXTURE_PR_COUNT="$(jq -r 'length' "$FIXTURE_DIR/prs.json")"
N_ROWS="$(printf '%s' "$ROWS_OUT" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$N_ROWS" = "$EXPECTED_FIXTURE_PR_COUNT" ]; then
  pass_msg "fixture-mode emits one row per PR in prs.json (n=$N_ROWS)"
else
  fail_msg "expected $EXPECTED_FIXTURE_PR_COUNT PR rows, got $N_ROWS"
fi

# --- Scenario 3: per-PR metric extraction ---
inc_scenario "Scenario 3: per-PR metrics (path, loc, plan, plan_eval, pr_eval)"

assert_row_field() {
  local pr_num="$1" field="$2" expected="$3"
  local actual
  actual="$(printf '%s' "$ROWS_OUT" | jq -r --argjson n "$pr_num" \
    --arg f "$field" '.[] | select(.pr_number == $n) | .[$f] | tostring' 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then
    pass_msg "PR #$pr_num $field=$expected"
  else
    fail_msg "PR #$pr_num $field expected=$expected actual=$actual"
  fi
}

# Expected per fixture (see inline comments above):
#   PR 101 (A): loc=4   plan=2 plan_eval=-- pr_eval=0
#   PR 102 (B): loc=160 plan=3 plan_eval=2  pr_eval=3
#   PR 103 (C): loc=800 plan=5 plan_eval=3  pr_eval=5
#   PR 104 (D): loc=3   plan=2 plan_eval=-- pr_eval=2

assert_row_field 101 path A
assert_row_field 101 loc 4
assert_row_field 101 plan 2
assert_row_field 101 plan_eval "--"
assert_row_field 101 pr_eval 0

assert_row_field 102 path B
assert_row_field 102 loc 160
assert_row_field 102 plan 3
assert_row_field 102 plan_eval 2
assert_row_field 102 pr_eval 3

assert_row_field 103 path C
assert_row_field 103 loc 800
assert_row_field 103 plan 5
assert_row_field 103 plan_eval 3
assert_row_field 103 pr_eval 5

assert_row_field 104 path D
assert_row_field 104 loc 3
assert_row_field 104 plan 2
assert_row_field 104 plan_eval "--"
assert_row_field 104 pr_eval 2

# --- Scenario 4: per-PATH aggregation + summary table ---
inc_scenario "Scenario 4: rendered summary table"

TABLE_OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" 2>/dev/null || true)"

EXPECTED_HEADER="PATH | N  | median diff | median plan | median plan-eval | median pr-eval | ratio pr-eval:diff | ratio plan-eval:diff"
if printf '%s' "$TABLE_OUT" | grep -qF "$EXPECTED_HEADER"; then
  pass_msg "table contains exact header row"
else
  fail_msg "table missing exact header row (got:\n$TABLE_OUT\n)"
fi

# Banner: 'OVER-EVAL REPORT' present.
if printf '%s' "$TABLE_OUT" | grep -q '^OVER-EVAL REPORT'; then
  pass_msg "banner present"
else
  fail_msg "banner missing"
fi

# One row per PATH with >=1 PR in the fixture (all 4 PATHs are populated).
for letter in A B C D; do
  if printf '%s' "$TABLE_OUT" | grep -Eq "^${letter}[[:space:]]*\|"; then
    pass_msg "row for PATH $letter present"
  else
    fail_msg "row for PATH $letter missing"
  fi
done

# PATH A row uses '--' for median plan-eval (lifecycle skips evaluate-issue-plan).
A_ROW="$(printf '%s' "$TABLE_OUT" | grep -E "^A[[:space:]]*\|" | head -1)"
B_ROW="$(printf '%s' "$TABLE_OUT" | grep -E "^B[[:space:]]*\|" | head -1)"
D_ROW="$(printf '%s' "$TABLE_OUT" | grep -E "^D[[:space:]]*\|" | head -1)"

case "$A_ROW" in *--*) pass_msg "PATH A row has '--' in plan-eval columns" ;;
                  *) fail_msg "PATH A row missing '--' (got: $A_ROW)" ;;
esac
case "$D_ROW" in *--*) pass_msg "PATH D row has '--' in plan-eval columns" ;;
                  *) fail_msg "PATH D row missing '--' (got: $D_ROW)" ;;
esac

# PATH B row's pr-eval ratio is formatted with one decimal + 'x' (3/160=0.0x).
if printf '%s' "$B_ROW" | grep -Eq '[0-9]+\.[0-9]x'; then
  pass_msg "PATH B row has 1-decimal ratio formatting (e.g. 0.0x)"
else
  fail_msg "PATH B row missing 1-decimal ratio (got: $B_ROW)"
fi

# PATH D's pr-eval/diff is 2/3 ≈ 0.7x — sanity-check the rounding.
if printf '%s' "$D_ROW" | grep -qF "0.7x"; then
  pass_msg "PATH D row computes 0.7x (2/3 rounded to 1 decimal)"
else
  fail_msg "PATH D row missing expected 0.7x ratio (got: $D_ROW)"
fi

# --- Scenario 5: TOP-5 OVER-EVAL OUTLIERS section ---
# The static fixture's PR 302 is the synthetic outlier (loc=8, pr_eval=240
# → 30.0x). It must rank first in the outlier list.
inc_scenario "Scenario 5: TOP-5 outliers (ranking, format, 5-row cap)"

OUT3="$(bash "$HELPER" --fixture "$FIXTURE_DIR" 2>/dev/null || true)"

if printf '%s' "$OUT3" | grep -q '^TOP-5 OVER-EVAL OUTLIERS'; then
  pass_msg "TOP-5 OVER-EVAL OUTLIERS header present"
else
  fail_msg "TOP-5 OVER-EVAL OUTLIERS header missing"
fi

# Outlier section appears AFTER the table header.
HDR_LINE="$(printf '%s\n' "$OUT3" | grep -n '^PATH | N' | head -1 | cut -d: -f1)"
OUTLIER_LINE="$(printf '%s\n' "$OUT3" | grep -n '^TOP-5 OVER-EVAL OUTLIERS' | head -1 | cut -d: -f1)"
if [ -n "$HDR_LINE" ] && [ -n "$OUTLIER_LINE" ] && [ "$OUTLIER_LINE" -gt "$HDR_LINE" ]; then
  pass_msg "outlier section appears after the per-PATH table"
else
  fail_msg "outlier section ordering wrong (hdr=$HDR_LINE outlier=$OUTLIER_LINE)"
fi

# Outlier PR #302 appears first (highest ratio = 30.0x).
FIRST_OUTLIER="$(printf '%s\n' "$OUT3" | awk '/^TOP-5 OVER-EVAL OUTLIERS/{flag=1; next} flag && /^PR #/{print; exit}')"
case "$FIRST_OUTLIER" in
  "PR #302 "*"30.0x"*) pass_msg "outlier PR #302 ranks first with 30.0x" ;;
  *) fail_msg "first outlier row unexpected: $FIRST_OUTLIER" ;;
esac

# Format spec: 'PR #N (PATH B): <loc> LOC diff, <pr_eval> lines pr-eval → <ratio>x'
case "$FIRST_OUTLIER" in
  "PR #302 (PATH B): 8 LOC diff, 240 lines pr-eval → 30.0x") pass_msg "outlier row uses spec format" ;;
  *) fail_msg "outlier row format mismatch: $FIRST_OUTLIER" ;;
esac

# --- 5-row cap test ---
# Generated inline (six near-identical PRs) — purely a scale check; not
# worth carving into static fixture files.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIX4="$TMP/fix4"; mkdir -p "$FIX4"

# Six high-ratio PRs in PATH B; outlier list must cap at 5.
{
  echo '['
  sep=""
  for i in 1 2 3 4 5 6; do
    n=$((500 + i))
    iss=$((600 + i))
    day=$(printf "%02d" "$i")
    printf '%s  {"number":%d,"title":"feat: hi%d","additions":1,"deletions":1,"body":"Closes #%d","mergedAt":"2026-05-%sT10:00:00Z"}\n' "$sep" "$n" "$i" "$iss" "$day"
    sep=","
  done
  echo ']'
} > "$FIX4/prs.json"

PR_EVAL_BODY2="## Evaluation"
for i in $(seq 1 50); do
  PR_EVAL_BODY2="${PR_EVAL_BODY2}
Line ${i}"
done
for i in 1 2 3 4 5 6; do
  n=$((500 + i))
  iss=$((600 + i))
  jq -n --arg body "$PR_EVAL_BODY2" --argjson n "$n" \
    '{number:$n,additions:1,deletions:1,comments:[{author:{login:"rjskene"},body:$body,createdAt:"2026-05-11T11:00:00Z"}]}' \
    > "$FIX4/pr-${n}.json"
  cat > "$FIX4/issue-${iss}.json" <<J
{"number":${iss},"labels":[],"comments":[
  {"body":"## Implementation Plan\nBody 1","createdAt":"2026-05-11T08:00:00Z"}
]}
J
done

OUT4="$(bash "$HELPER" --fixture "$FIX4" 2>/dev/null || true)"
OUTLIER_ROWS="$(printf '%s\n' "$OUT4" | awk '/^TOP-5 OVER-EVAL OUTLIERS/{flag=1; next} flag && /^PR #/{count++} END{print count+0}')"
if [ "$OUTLIER_ROWS" = "5" ]; then
  pass_msg "outlier list capped at 5 rows even with 6 high-ratio PRs"
else
  fail_msg "expected 5 outlier rows, got $OUTLIER_ROWS"
fi

# --- Scenario 6: live-mode smoke + repo validation ---
inc_scenario "Scenario 6: live-mode smoke + PIPELINE_REPO validation"

# 6a: no fixture + PIPELINE_REPO unset → non-zero exit + clear error.
ERR6A="$(env -u PIPELINE_REPO bash "$HELPER" --limit 1 --dry-run 2>&1)"
RC6A=$?
if [ "$RC6A" -ne 0 ]; then
  pass_msg "missing PIPELINE_REPO causes non-zero exit"
else
  fail_msg "expected non-zero exit when PIPELINE_REPO unset, got rc=$RC6A"
fi
case "$ERR6A" in
  *PIPELINE_REPO*) pass_msg "error message mentions PIPELINE_REPO" ;;
  *) fail_msg "error message missing PIPELINE_REPO mention: $ERR6A" ;;
esac

# 6b: live smoke — calls real `gh`. Skip under CI or when env not configured.
if [ -n "${CI:-}" ]; then
  pass_msg "Scenario 6b skipped under CI"
elif [ -z "${PIPELINE_REPO:-}" ]; then
  pass_msg "Scenario 6b skipped (PIPELINE_REPO unset locally)"
elif ! command -v gh >/dev/null 2>&1; then
  pass_msg "Scenario 6b skipped (gh CLI not installed)"
else
  OUT6B="$(bash "$HELPER" --limit 1 --dry-run 2>/dev/null || true)"
  if printf '%s\n' "$OUT6B" | grep -Eq '^would-fetch: PR #[0-9]+'; then
    pass_msg "live --dry-run prints 'would-fetch: PR #<N>'"
  else
    fail_msg "live --dry-run did not print expected line (got: $OUT6B)"
  fi
fi

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
