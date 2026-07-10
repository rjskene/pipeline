#!/bin/bash
set -uo pipefail
#
# Tests for scripts/late-error-report.sh — dogfood-only one-off measurement
# (issue #574 / parent #450). Walks the last N merged feature PRs and
# categorizes each `## Evaluation` "Changes Requested" finding by the
# earliest stage at which it was detectable (issue|plan|plan-eval|pr-eval).
#
# Uses fixture mode (--fixture <dir>) so no live `gh` calls are required.
# The fixture directory must contain:
#   - prs.json           — synthetic `gh pr list ... --json number,title,...` payload
#   - pr-<N>.json        — synthetic `gh pr view <N> --json ...` payload (one per feature PR)
#   - issue-<N>.json     — synthetic `gh issue view <N> --json ...` payload (one per linked issue)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/late-error-report.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/late-error-report"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

inc_scenario() { echo ""; echo "-- $1 --"; }

# --- Scenario 1: scaffolding ---
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/late-error-report.sh"
else
  fail_msg "script file missing at scripts/late-error-report.sh"
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

# --- Scenario 2: fixture loader emits one row per FINDING (not per PR) ---
inc_scenario "Scenario 2: --emit-rows-json emits one row per finding"

ROWS_OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-rows-json 2>/dev/null || true)"
ROWS_RC=$?
if [ "$ROWS_RC" -eq 0 ]; then
  pass_msg "fixture-mode run exits 0"
else
  fail_msg "fixture-mode run exited non-zero (rc=$ROWS_RC)"
fi

# Expected: PR 101 has 3 findings, 102 has 4, 103 has 5, 104 has 3 → 15 rows.
# Release PRs (901/902) excluded entirely.
EXPECTED_TOTAL_FINDINGS=15
N_ROWS="$(printf '%s' "$ROWS_OUT" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$N_ROWS" = "$EXPECTED_TOTAL_FINDINGS" ]; then
  pass_msg "fixture-mode emits one row per finding across eligible PRs (n=$N_ROWS)"
else
  fail_msg "expected $EXPECTED_TOTAL_FINDINGS finding rows, got $N_ROWS"
fi

# --- Scenario 3: stage categorization per finding ---
inc_scenario "Scenario 3: per-finding stage categorization"

# Helper: count finding rows for a given PR + stage combo.
count_pr_stage() {
  local pr_num="$1" stage="$2"
  printf '%s' "$ROWS_OUT" | jq -r --argjson n "$pr_num" --arg s "$stage" \
    '[.[] | select(.pr_number == $n and .stage == $s)] | length' 2>/dev/null
}

assert_pr_stage_count() {
  local pr_num="$1" stage="$2" expected="$3"
  local actual
  actual="$(count_pr_stage "$pr_num" "$stage")"
  if [ "$actual" = "$expected" ]; then
    pass_msg "PR #$pr_num has $expected finding(s) at stage=$stage"
  else
    fail_msg "PR #$pr_num stage=$stage expected=$expected actual=$actual"
  fi
}

# PR 101 (A): issue, plan, pr-eval
assert_pr_stage_count 101 issue 1
assert_pr_stage_count 101 plan 1
assert_pr_stage_count 101 pr-eval 1
assert_pr_stage_count 101 plan-eval 0

# PR 102 (B): issue, plan, plan-eval, pr-eval — all four stages
assert_pr_stage_count 102 issue 1
assert_pr_stage_count 102 plan 1
assert_pr_stage_count 102 plan-eval 1
assert_pr_stage_count 102 pr-eval 1

# PR 103 (C): 2x plan, plan-eval, 2x pr-eval
assert_pr_stage_count 103 plan 2
assert_pr_stage_count 103 plan-eval 1
assert_pr_stage_count 103 pr-eval 2

# PR 104 (D): issue, 2x pr-eval
assert_pr_stage_count 104 issue 1
assert_pr_stage_count 104 pr-eval 2

# Path attribution per PR.
for combo in "101 A" "102 B" "103 C" "104 D"; do
  pr="${combo% *}"; expected_path="${combo#* }"
  actual_path="$(printf '%s' "$ROWS_OUT" | jq -r --argjson n "$pr" \
    '[.[] | select(.pr_number == $n)] | first | .path' 2>/dev/null)"
  if [ "$actual_path" = "$expected_path" ]; then
    pass_msg "PR #$pr resolves to PATH $expected_path"
  else
    fail_msg "PR #$pr PATH expected=$expected_path actual=$actual_path"
  fi
done

# --- Scenario 4: per-PATH aggregation + summary table ---
inc_scenario "Scenario 4: rendered summary table"

TABLE_OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" 2>/dev/null || true)"

EXPECTED_HEADER="PATH | N findings | issue | plan | plan-eval | pr-eval | late-detectable rate"
if printf '%s' "$TABLE_OUT" | grep -qF "$EXPECTED_HEADER"; then
  pass_msg "table contains exact header row"
else
  fail_msg "table missing exact header row (got:\n$TABLE_OUT\n)"
fi

if printf '%s' "$TABLE_OUT" | grep -q '^LATE-ERROR REPORT'; then
  pass_msg "banner present"
else
  fail_msg "banner missing"
fi

for letter in A B C D; do
  if printf '%s' "$TABLE_OUT" | grep -Eq "^${letter}[[:space:]]*\|"; then
    pass_msg "row for PATH $letter present"
  else
    fail_msg "row for PATH $letter missing"
  fi
done

# Late-detectable rate sanity-check: PATH B = (1+1+1)/4 = 0.75
B_ROW="$(printf '%s' "$TABLE_OUT" | grep -E "^B[[:space:]]*\|" | head -1)"
if printf '%s' "$B_ROW" | grep -qF "0.75"; then
  pass_msg "PATH B late-detectable rate is 0.75"
else
  fail_msg "PATH B row missing 0.75 rate (got: $B_ROW)"
fi

# PATH D rate = (1+0+0)/3 ≈ 0.33
D_ROW="$(printf '%s' "$TABLE_OUT" | grep -E "^D[[:space:]]*\|" | head -1)"
if printf '%s' "$D_ROW" | grep -qE '0\.33'; then
  pass_msg "PATH D late-detectable rate is 0.33"
else
  fail_msg "PATH D row missing 0.33 rate (got: $D_ROW)"
fi

# --- Scenario 5: release-PR exclusion ---
inc_scenario "Scenario 5: release-PR exclusion"

ROWS5="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-rows-json 2>/dev/null || true)"
for n in 901 902; do
  has_n="$(printf '%s' "$ROWS5" | jq --argjson n "$n" 'any(.[]; .pr_number == $n)' 2>/dev/null)"
  if [ "$has_n" = "false" ]; then
    pass_msg "release PR #$n is NOT in --emit-rows-json output"
  else
    fail_msg "release PR #$n leaked into --emit-rows-json output"
  fi
done

BANNER5="$(printf '%s\n' "$TABLE_OUT" | grep '^LATE-ERROR REPORT' | head -1)"
if printf '%s' "$BANNER5" | grep -qE 'last 4 feature PRs.*2 release PRs excluded'; then
  pass_msg "banner reports eligible feature-PR count + excluded release-PR count"
else
  fail_msg "banner does not report 'last 4 feature PRs ... 2 release PRs excluded' (got: $BANNER5)"
fi

# --- Scenario 6: TOP-5 outliers ---
inc_scenario "Scenario 6: TOP-5 outliers"

if printf '%s' "$TABLE_OUT" | grep -q '^TOP-5 LATE-ERROR OUTLIERS'; then
  pass_msg "TOP-5 LATE-ERROR OUTLIERS header present"
else
  fail_msg "TOP-5 LATE-ERROR OUTLIERS header missing"
fi

# Expected outlier ranking by per-PR late-rate:
#   PR 102 (B): 3/4 = 0.75
#   PR 101 (A): 2/3 = 0.667
#   PR 103 (C): 3/5 = 0.6
#   PR 104 (D): 1/3 = 0.333
FIRST_OUTLIER="$(printf '%s\n' "$TABLE_OUT" | awk '/^TOP-5 LATE-ERROR OUTLIERS/{flag=1; next} flag && /^PR #/{print; exit}')"
case "$FIRST_OUTLIER" in
  "PR #102 "*) pass_msg "outlier PR #102 ranks first (3/4 late-detectable)" ;;
  *) fail_msg "first outlier row unexpected: $FIRST_OUTLIER" ;;
esac

# Format spec sanity: contains "PATH" and "late-detectable" and rate-like number.
case "$FIRST_OUTLIER" in
  *"PATH B"*"late-detectable"*) pass_msg "outlier row uses spec format" ;;
  *) fail_msg "outlier row format mismatch: $FIRST_OUTLIER" ;;
esac

# --- Scenario 7: live-mode smoke + PIPELINE_REPO validation ---
inc_scenario "Scenario 7: live-mode smoke + PIPELINE_REPO validation"

# 7a: PIPELINE_REPO unset + no fixture → non-zero exit + clear error.
ERR7A="$(env -u PIPELINE_REPO bash "$HELPER" --limit 1 --dry-run 2>&1)"
RC7A=$?
if [ "$RC7A" -ne 0 ]; then
  pass_msg "missing PIPELINE_REPO causes non-zero exit"
else
  fail_msg "expected non-zero exit when PIPELINE_REPO unset, got rc=$RC7A"
fi
case "$ERR7A" in
  *PIPELINE_REPO*) pass_msg "error message mentions PIPELINE_REPO" ;;
  *) fail_msg "error message missing PIPELINE_REPO mention: $ERR7A" ;;
esac

# 7b: live smoke — calls real `gh`. Skip under CI or when env not configured.
if [ -n "${CI:-}" ]; then
  pass_msg "Scenario 7b skipped under CI"
elif [ -z "${PIPELINE_REPO:-}" ]; then
  pass_msg "Scenario 7b skipped (PIPELINE_REPO unset locally)"
elif ! command -v gh >/dev/null 2>&1; then
  pass_msg "Scenario 7b skipped (gh CLI not installed)"
else
  OUT7B="$(bash "$HELPER" --limit 20 --dry-run 2>/dev/null || true)"
  if printf '%s\n' "$OUT7B" | grep -Eq '^would-fetch: PR #[0-9]+'; then
    pass_msg "live --dry-run prints 'would-fetch: PR #<N>'"
  else
    fail_msg "live --dry-run did not print expected line (got: $OUT7B)"
  fi
fi

# --- Scenario 8: unknown flag rejects ---
inc_scenario "Scenario 8: unknown flag rejects"

if bash "$HELPER" --bogus 2>/dev/null; then
  fail_msg "unknown flag should exit non-zero"
else
  pass_msg "unknown flag exits non-zero"
fi

# --- Scenario 9: CRLF-jq seam — dry-run number sweep has no stray CR (#1158) ---
# Git-for-Windows jq (msvcrt) emits \r\n on every output line. The --dry-run
# loop reads `jq -r '.[].number' | while read -r n` and echoes `would-fetch:
# PR #$n`; under CRLF jq `n="101\r"`, so every line trails a carriage return.
# This is the representative guard for the byte-identical cosmetic sweep class
# (late-error / over-eval / compliance-backfill). A fake jq earlier on PATH
# reproduces the msvcrt CR faithfully on an LF-only host.
inc_scenario "Scenario 9: CRLF-jq seam — dry-run 'would-fetch' lines carry no CR"

# shellcheck source=_lib/crlf-jq-seam.sh
source "$REPO_ROOT/tests/_lib/crlf-jq-seam.sh"
CRLF_BIN9="$(mktemp -d)"
if make_crlf_jq_bin "$CRLF_BIN9/bin"; then
  DRY9="$(PATH="$CRLF_BIN9/bin:$PATH" bash "$HELPER" --fixture "$FIXTURE_DIR" --dry-run 2>/dev/null || true)"

  # PR numbers must still be the eligible feature PRs (101-104; release PRs excluded).
  if printf '%s\n' "$DRY9" | grep -Eq '^would-fetch: PR #101' \
     && printf '%s\n' "$DRY9" | grep -Eq '^would-fetch: PR #104'; then
    pass_msg "CRLF-seam: dry-run still lists the eligible feature PRs (#101..#104)"
  else
    fail_msg "CRLF-seam: dry-run PR numbers unexpected (got: $DRY9)"
  fi

  if ! printf '%s' "$DRY9" | grep -q $'\r'; then
    pass_msg "CRLF-seam: no stray CR in dry-run 'would-fetch' output"
  else
    fail_msg "CRLF-seam: 'would-fetch' lines carry a trailing CR under CRLF jq"
  fi
else
  fail_msg "CRLF-seam: fake-jq seam setup failed (non-vacuity guard)"
fi
rm -rf "$CRLF_BIN9"

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
