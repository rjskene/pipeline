#!/bin/bash
set -uo pipefail

export PIPELINE_LOGS_ENABLED=true
#
# Tests for the supersession_candidates JSON key in scripts/analyze-issues.sh.
#
# Cross-references open non-stage issues against merged PRs (from prs.json in
# fixture mode) and surfaces PRs that may already have done the work, keyed on
# body file-path overlap and/or conventional-commit scope match.
#
# Uses fixture mode (--fixture <dir>) so no live `gh` calls are required. The
# fixture directory must contain:
#   - issues.json — the `gh issue list ... --json number,title,body,labels,createdAt` payload
#   - prs.json    — the `gh pr list --state merged --json number,mergedAt,files,title,body` payload
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/analyze-issues.sh"
FIXTURE_ROOT="$REPO_ROOT/tests/fixtures/analyze-issues"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

inc_scenario() { echo ""; echo "-- $1 --"; }

# Run helper from $TMP so `.claude/logs/` is created there (helper writes
# output relative to PWD).
run_helper() {
  local fixture="$1"
  mkdir -p "$TMP/.claude/logs"
  ( cd "$TMP" && bash "$HELPER" --fixture "$fixture" )
}

# --- Scenario 1: supersession-basic surfaces PR 100 ---
inc_scenario "Scenario 1: supersession-basic surfaces overlapping merged PR"
FIX_BASIC="$FIXTURE_ROOT/supersession-basic"
out_basic=$(run_helper "$FIX_BASIC" 2>&1)
rc_basic=$?
echo "$out_basic" | sed 's/^/    /'
shortlist_basic=$(echo "$out_basic" | tail -n 1)

# (i) helper exits 0 in the basic fixture
if [ "$rc_basic" -eq 0 ] && [ -f "$shortlist_basic" ]; then
  pass_msg "scenario 1: exit 0 and shortlist file exists"
else
  fail_msg "scenario 1: exit 0 and shortlist file exists (rc=$rc_basic, file=$shortlist_basic)"
fi

if [ -f "$shortlist_basic" ]; then
  # (ii) supersession_candidates length >= 1
  sc_len=$(jq '.supersession_candidates | length' "$shortlist_basic" 2>/dev/null || echo "0")
  if [ "$sc_len" -ge 1 ]; then
    pass_msg "scenario 1: supersession_candidates | length >= 1 (got $sc_len)"
  else
    fail_msg "scenario 1: supersession_candidates | length >= 1 (got $sc_len)"
  fi

  # (ii) PR 100 surfaced
  has_100=$(jq -r '[.supersession_candidates[].candidate_prs[] | select(.pr == 100)] | length' "$shortlist_basic" 2>/dev/null || echo "0")
  if [ "$has_100" -ge 1 ]; then
    pass_msg "scenario 1: PR 100 present in candidate_prs"
  else
    fail_msg "scenario 1: PR 100 present in candidate_prs (got $has_100)"
    jq '.supersession_candidates' "$shortlist_basic" | sed 's/^/      /'
  fi

  # (iii) PR 102 absent (predates issue.createdAt)
  has_102=$(jq -r '[.supersession_candidates[].candidate_prs[] | select(.pr == 102)] | length' "$shortlist_basic" 2>/dev/null || echo "0")
  if [ "$has_102" = "0" ]; then
    pass_msg "scenario 1: PR 102 absent (merged before issue createdAt)"
  else
    fail_msg "scenario 1: PR 102 absent (got $has_102)"
  fi

  # (iv) PR 101 absent (zero file overlap, no scope match)
  has_101=$(jq -r '[.supersession_candidates[].candidate_prs[] | select(.pr == 101)] | length' "$shortlist_basic" 2>/dev/null || echo "0")
  if [ "$has_101" = "0" ]; then
    pass_msg "scenario 1: PR 101 absent (zero overlap, no scope match)"
  else
    fail_msg "scenario 1: PR 101 absent (got $has_101)"
  fi

  # (vi) row shape: {issue:<int>, candidate_prs:[{pr:<int>, files_overlap_count:<int>, scope_match:<bool>}]}
  shape_ok=$(jq -r '
    .supersession_candidates
    | all(.[];
        (.issue | type == "number")
        and (.candidate_prs | type == "array")
        and (.candidate_prs | all(.[];
              (.pr | type == "number")
              and (.files_overlap_count | type == "number")
              and (.scope_match | type == "boolean"))))
  ' "$shortlist_basic" 2>/dev/null || echo "false")
  if [ "$shape_ok" = "true" ]; then
    pass_msg "scenario 1: row shape keys/types correct (issue:int, candidate_prs[].pr:int, files_overlap_count:int, scope_match:bool)"
  else
    fail_msg "scenario 1: row shape keys/types correct (got $shape_ok)"
    jq '.supersession_candidates' "$shortlist_basic" | sed 's/^/      /'
  fi

  # PR 100 should report files_overlap_count == 2 (both scripts overlap) and scope_match true.
  ovl_100=$(jq -r '[.supersession_candidates[].candidate_prs[] | select(.pr == 100) | .files_overlap_count][0] // -1' "$shortlist_basic" 2>/dev/null || echo "-1")
  if [ "$ovl_100" = "2" ]; then
    pass_msg "scenario 1: PR 100 files_overlap_count == 2"
  else
    fail_msg "scenario 1: PR 100 files_overlap_count == 2 (got $ovl_100)"
  fi
  scope_100=$(jq -r '[.supersession_candidates[].candidate_prs[] | select(.pr == 100) | .scope_match][0] // false' "$shortlist_basic" 2>/dev/null || echo "false")
  if [ "$scope_100" = "true" ]; then
    pass_msg "scenario 1: PR 100 scope_match == true (title \"fix(spawn): ...\" matches scope \"spawn\")"
  else
    fail_msg "scenario 1: PR 100 scope_match == true (got $scope_100)"
  fi

  # (vii) total supersession_candidates length caps at 20
  cap_ok=$(jq -r '.supersession_candidates | length <= 20' "$shortlist_basic" 2>/dev/null || echo "false")
  if [ "$cap_ok" = "true" ]; then
    pass_msg "scenario 1: supersession_candidates length <= 20 (cap)"
  else
    fail_msg "scenario 1: supersession_candidates length <= 20 (cap)"
  fi
fi

# --- Scenario 2: supersession-empty yields empty array ---
inc_scenario "Scenario 2: supersession-empty yields empty array"
FIX_EMPTY="$FIXTURE_ROOT/supersession-empty"
out_empty=$(run_helper "$FIX_EMPTY" 2>&1)
rc_empty=$?
echo "$out_empty" | sed 's/^/    /'
shortlist_empty=$(echo "$out_empty" | tail -n 1)

# (i) helper exits 0 in the empty fixture
if [ "$rc_empty" -eq 0 ] && [ -f "$shortlist_empty" ]; then
  pass_msg "scenario 2: exit 0 and shortlist file exists"
else
  fail_msg "scenario 2: exit 0 and shortlist file exists (rc=$rc_empty, file=$shortlist_empty)"
fi

if [ -f "$shortlist_empty" ]; then
  # (v) supersession_candidates == []
  empty_val=$(jq -c '.supersession_candidates' "$shortlist_empty" 2>/dev/null || echo "null")
  if [ "$empty_val" = "[]" ]; then
    pass_msg "scenario 2: supersession_candidates == []"
  else
    fail_msg "scenario 2: supersession_candidates == [] (got '$empty_val')"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
