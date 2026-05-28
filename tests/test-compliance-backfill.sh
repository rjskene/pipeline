#!/bin/bash
set -uo pipefail
#
# Tests for scripts/compliance-backfill.sh — dogfood-only retroactive
# TDD-compliance backfill (issue #575). Walks merged feature PRs, invokes
# the existing scripts/audit-compliance.sh per PR with injection-flag JSON,
# and emits a per-PATH PASS/SKIP/N-A aggregation + overall SKIP-rate.
#
# Uses fixture mode (--fixture <dir>) so no live `gh` calls are required.
# The fixture directory must contain:
#   - prs.json              — synthetic `gh pr list ... --json ...` payload
#   - pr-<N>.json           — per-PR payload (one per eligible feature PR)
#   - issue-<N>.json        — per-linked-issue payload (labels for PATH)
#   - commits-<N>.json      — `[{oid,files:[paths]}, ...]` per PR
#   - files-<N>.json        — `[paths]` per PR
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/compliance-backfill.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/compliance-backfill"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

# --- Scenario 1: scaffolding (script existence + shebang + --help banner) ---
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/compliance-backfill.sh"
else
  fail_msg "script file missing at scripts/compliance-backfill.sh"
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

# --- Scenario 2: fixture loader runs end-to-end ---
inc_scenario "Scenario 2: fixture-mode run exits 0"

TABLE_OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" 2>/dev/null)"
TABLE_RC=$?
if [ "$TABLE_RC" -eq 0 ]; then
  pass_msg "fixture-mode run exits 0"
else
  fail_msg "fixture-mode run exited non-zero (rc=$TABLE_RC)"
fi

# --- Scenario 3: per-PATH greppable aggregation rows ---
inc_scenario "Scenario 3: per-PATH aggregation row counts"

# PATH A: 1 PR (101), TDD row omitted by audit-compliance.sh, classified as
# `omitted` and excluded from PASS/SKIP/N-A — SKIP-rate is undefined ("--").
if printf '%s' "$TABLE_OUT" | grep -qF 'N=1, PASS=0, SKIP=0, N/A=0, SKIP-rate=--'; then
  pass_msg "PATH A row: N=1, PASS=0, SKIP=0, N/A=0, SKIP-rate=--"
else
  fail_msg "PATH A row mismatch (got:\n$TABLE_OUT\n)"
fi

# PATH B: 3 PRs — PASS=1 (102), SKIP=1 (103), N/A=1 (104), SKIP-rate=50.0%
if printf '%s' "$TABLE_OUT" | grep -qF 'N=3, PASS=1, SKIP=1, N/A=1, SKIP-rate=50.0%'; then
  pass_msg "PATH B row: N=3, PASS=1, SKIP=1, N/A=1, SKIP-rate=50.0%"
else
  fail_msg "PATH B row mismatch (got:\n$TABLE_OUT\n)"
fi

# PATH C: 1 PR (105) — PASS=1, SKIP-rate=0.0%
if printf '%s' "$TABLE_OUT" | grep -qF 'N=1, PASS=1, SKIP=0, N/A=0, SKIP-rate=0.0%'; then
  pass_msg "PATH C row: N=1, PASS=1, SKIP=0, N/A=0, SKIP-rate=0.0%"
else
  fail_msg "PATH C row mismatch (got:\n$TABLE_OUT\n)"
fi

# PATH D: 2 PRs — PASS=1 (106), SKIP=1 (107), SKIP-rate=50.0%
if printf '%s' "$TABLE_OUT" | grep -qF 'N=2, PASS=1, SKIP=1, N/A=0, SKIP-rate=50.0%'; then
  pass_msg "PATH D row: N=2, PASS=1, SKIP=1, N/A=0, SKIP-rate=50.0%"
else
  fail_msg "PATH D row mismatch (got:\n$TABLE_OUT\n)"
fi

# Each PATH row is line-anchored on the PATH letter.
for letter in A B C D; do
  if printf '%s\n' "$TABLE_OUT" | grep -Eq "^PATH ${letter}[[:space:]]"; then
    pass_msg "row for PATH $letter present (line-anchored)"
  else
    fail_msg "row for PATH $letter missing (line-anchored)"
  fi
done

# --- Scenario 4: overall SKIP-rate footer ---
inc_scenario "Scenario 4: overall SKIP-rate footer"

# Overall denominator excludes N/A and PATH-A-omitted rows; numerator = SKIP.
# PASS = 3 (102, 105, 106); SKIP = 2 (103, 107); SKIP-rate = 2/(3+2) = 40.0%.
if printf '%s' "$TABLE_OUT" | grep -qF 'Overall SKIP-rate=40.0%'; then
  pass_msg "overall footer: SKIP-rate=40.0%"
else
  fail_msg "overall footer SKIP-rate missing or wrong (got:\n$TABLE_OUT\n)"
fi

# --- Scenario 5: --emit-rows-json shape ---
inc_scenario "Scenario 5: --emit-rows-json"

ROWS_OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" --emit-rows-json 2>/dev/null)"
N_ROWS="$(printf '%s' "$ROWS_OUT" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$N_ROWS" = "7" ]; then
  pass_msg "--emit-rows-json emits 7 objects (one per eligible feature PR)"
else
  fail_msg "expected 7 row objects, got $N_ROWS"
fi

# Schema: every object has the four required keys.
if printf '%s' "$ROWS_OUT" | jq -e 'all(.[]; has("pr_number") and has("path") and has("verdict") and has("issue_number"))' >/dev/null 2>&1; then
  pass_msg "every row has {pr_number, path, verdict, issue_number}"
else
  fail_msg "row objects missing required keys (got: $ROWS_OUT)"
fi

# Verdict domain.
if printf '%s' "$ROWS_OUT" | jq -e 'all(.[]; .verdict as $v | ["PASS","SKIP","N/A","omitted"] | index($v) != null)' >/dev/null 2>&1; then
  pass_msg "verdict ∈ {PASS, SKIP, N/A, omitted}"
else
  fail_msg "verdict out of expected domain (got: $ROWS_OUT)"
fi

assert_row_verdict() {
  local pr_num="$1" expected_path="$2" expected_verdict="$3" expected_issue="$4"
  local got_path got_verdict got_issue
  got_path="$(printf '%s' "$ROWS_OUT" | jq -r --argjson n "$pr_num" '.[] | select(.pr_number == $n) | .path')"
  got_verdict="$(printf '%s' "$ROWS_OUT" | jq -r --argjson n "$pr_num" '.[] | select(.pr_number == $n) | .verdict')"
  got_issue="$(printf '%s' "$ROWS_OUT" | jq -r --argjson n "$pr_num" '.[] | select(.pr_number == $n) | .issue_number')"
  if [ "$got_path" = "$expected_path" ] && [ "$got_verdict" = "$expected_verdict" ] && [ "$got_issue" = "$expected_issue" ]; then
    pass_msg "PR #$pr_num path=$expected_path verdict=$expected_verdict issue=$expected_issue"
  else
    fail_msg "PR #$pr_num expected (path=$expected_path verdict=$expected_verdict issue=$expected_issue) actual (path=$got_path verdict=$got_verdict issue=$got_issue)"
  fi
}

assert_row_verdict 101 A omitted 201
assert_row_verdict 102 B PASS 202
assert_row_verdict 103 B SKIP 203
assert_row_verdict 104 B "N/A" 204
assert_row_verdict 105 C PASS 205
assert_row_verdict 106 D PASS 206
assert_row_verdict 107 D SKIP 207

# --- Scenario 6: release-PR exclusion ---
inc_scenario "Scenario 6: release-PR exclusion (PR 901)"

has_901_rows="$(printf '%s' "$ROWS_OUT" | jq 'any(.[]; .pr_number == 901)')"
if [ "$has_901_rows" = "false" ]; then
  pass_msg "release PR #901 not in --emit-rows-json output"
else
  fail_msg "release PR #901 leaked into --emit-rows-json output"
fi

# Release PR must not appear in the rendered table (no row line carrying 901).
if printf '%s' "$TABLE_OUT" | grep -qE '\b901\b'; then
  fail_msg "release PR #901 leaked into rendered table"
else
  pass_msg "release PR #901 not in rendered table"
fi

# Stderr should mention the excluded release PR count (matches over-eval-report shape).
ERR_OUT="$(bash "$HELPER" --fixture "$FIXTURE_DIR" 2>&1 >/dev/null)"
if printf '%s' "$ERR_OUT" | grep -qE 'compliance-backfill: 1 release PRs excluded'; then
  pass_msg "stderr reports 1 release PR excluded"
else
  fail_msg "stderr missing release-PR-excluded count (got: $ERR_OUT)"
fi

# --- Scenario 7: skipped-no-link counted (PR 108) ---
inc_scenario "Scenario 7: skipped-no-link (PR 108)"

if printf '%s' "$ROWS_OUT" | jq -e 'any(.[]; .pr_number == 108) | not' >/dev/null 2>&1; then
  pass_msg "PR #108 (no Closes marker) absent from --emit-rows-json"
else
  fail_msg "PR #108 (no Closes marker) leaked into --emit-rows-json"
fi

if printf '%s' "$ERR_OUT" | grep -qE 'compliance-backfill: 1 non-release PRs skipped for missing Closes/Fixes/Resolves marker'; then
  pass_msg "stderr reports 1 non-release PR skipped for missing Closes/Fixes/Resolves marker"
else
  fail_msg "stderr missing skipped-no-link summary (got: $ERR_OUT)"
fi

# --- Scenario 8: dry-run is mandatory on every audit-compliance.sh call ---
inc_scenario "Scenario 8: audit-compliance.sh always invoked with --dry-run"

# Verifies the wrapper never posts ## Compliance Audit comments on merged PRs.
# An "invocation" is a line that runs the script via bash (matches both
# literal `bash .../audit-compliance.sh` and the variable form
# `bash "$AUDIT_COMPLIANCE"`). For each invocation line we capture the
# next 6 lines (the command may be backslash-continued across multiple
# lines) and assert `--dry-run` is present somewhere in that block.
if [ -f "$HELPER" ]; then
  INVOCATION_RE='bash[[:space:]]+("\$AUDIT_COMPLIANCE"|\$AUDIT_COMPLIANCE|.*audit-compliance\.sh)'
  INVOCATION_LINES=$(grep -nE "$INVOCATION_RE" "$HELPER" | cut -d: -f1)
  INVOCATIONS=0
  INVOCATIONS_OK=0
  for ln in $INVOCATION_LINES; do
    INVOCATIONS=$((INVOCATIONS + 1))
    block=$(sed -n "${ln},$((ln + 6))p" "$HELPER")
    if printf '%s' "$block" | grep -q -- '--dry-run'; then
      INVOCATIONS_OK=$((INVOCATIONS_OK + 1))
    fi
  done
  if [ "$INVOCATIONS" -gt 0 ] && [ "$INVOCATIONS" = "$INVOCATIONS_OK" ]; then
    pass_msg "every audit-compliance.sh call site includes --dry-run ($INVOCATIONS/$INVOCATIONS)"
  else
    fail_msg "audit-compliance.sh: $INVOCATIONS invocations, $INVOCATIONS_OK with --dry-run"
  fi
fi

# --- Scenario 9: live-mode PIPELINE_REPO validation ---
inc_scenario "Scenario 9: missing PIPELINE_REPO in live mode → non-zero exit"

if [ -f "$HELPER" ]; then
  ERR9="$(env -u PIPELINE_REPO bash "$HELPER" --limit 1 --dry-run 2>&1)"
  RC9=$?
  if [ "$RC9" -ne 0 ]; then
    pass_msg "missing PIPELINE_REPO causes non-zero exit"
  else
    fail_msg "expected non-zero exit when PIPELINE_REPO unset, got rc=$RC9"
  fi
  case "$ERR9" in
    *PIPELINE_REPO*) pass_msg "error message mentions PIPELINE_REPO" ;;
    *) fail_msg "error message missing PIPELINE_REPO mention: $ERR9" ;;
  esac
fi

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
