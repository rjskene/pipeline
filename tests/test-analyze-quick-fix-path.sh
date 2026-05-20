#!/bin/bash
set -uo pipefail

export PIPELINE_LOGS_ENABLED=true
#
# Tests that scripts/analyze-issues.sh treats `quick-fix` as a valid path label
# alongside `docs-only` and `multi-task`. A `quick-fix`-only issue (with a
# priority label) must NOT be surfaced in missing_label_candidates.
#
# PATH C of issue #344 (Task 3) — TDD: this test fails before the impl change
# because has_path() in scripts/analyze-issues.sh only recognizes docs-only and
# multi-task. The fix extends the predicate to also accept quick-fix.
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/analyze-issues.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# Minimal pipeline.config so the helper can source it.
cat > "$TMP/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/test-repo"
CFG

inc_scenario() { echo ""; echo "-- $1 --"; }

# Run helper from $TMP so `.claude/logs/` is created there.
run_helper() {
  local fixture="$1"
  mkdir -p "$TMP/.claude/logs"
  ( cd "$TMP" && bash "$HELPER" --fixture "$fixture" )
}

# Helper for deterministic createdAt timestamps in fixtures (ISO 8601, hours-ago).
hours_ago_iso() {
  date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ
}

CREATED_48H=$(hours_ago_iso 48)

# --- Scenario A: quick-fix + priority is a complete labelset (no missing path) ---
inc_scenario "Scenario A: quick-fix counts as a path label (priority present)"
FIXA="$TMP/fixA"; mkdir -p "$FIXA"
cat > "$FIXA/issues.json" <<J
[
  {"number":400,"title":"fix(spawn): tiny one-liner","body":"x","labels":[{"name":"priority/P2"},{"name":"quick-fix"}],"createdAt":"$CREATED_48H"}
]
J
outA=$(run_helper "$FIXA" 2>&1)
shortlistA=$(echo "$outA" | tail -n 1)
if [ -f "$shortlistA" ]; then
  rowA=$(jq -c '.missing_label_candidates[] | select(.issue == 400)' "$shortlistA" 2>/dev/null || echo "")
  if [ -z "$rowA" ]; then
    pass_msg "scenario A: quick-fix+priority issue NOT in missing_label_candidates"
  else
    fail_msg "scenario A: quick-fix+priority issue surfaced anyway (row='$rowA')"
    jq '.missing_label_candidates' "$shortlistA" | sed 's/^/      /'
  fi
fi

# --- Scenario B: quick-fix alone (no priority) — still surfaced for missing priority ONLY ---
# Regression-protects that has_path() recognizes quick-fix even when priority is
# missing: the row's .missing must be exactly ["priority"], not ["priority","path"].
inc_scenario "Scenario B: quick-fix-only issue missing priority surfaces ['priority'] (not path)"
FIXB="$TMP/fixB"; mkdir -p "$FIXB"
cat > "$FIXB/issues.json" <<J
[
  {"number":401,"title":"fix(spawn): another tiny one","body":"x","labels":[{"name":"quick-fix"}],"createdAt":"$CREATED_48H"}
]
J
outB=$(run_helper "$FIXB" 2>&1)
shortlistB=$(echo "$outB" | tail -n 1)
if [ -f "$shortlistB" ]; then
  rowB=$(jq -c '.missing_label_candidates[] | select(.issue == 401) | .missing' "$shortlistB" 2>/dev/null || echo "[]")
  if [ "$rowB" = '["priority"]' ]; then
    pass_msg "scenario B: quick-fix-only row .missing == [\"priority\"] (path satisfied)"
  else
    fail_msg "scenario B: quick-fix-only row .missing (got '$rowB')"
  fi
fi

# --- Scenario C: regression — docs-only still counts as path ---
inc_scenario "Scenario C: docs-only still a valid path label (regression guard)"
FIXC="$TMP/fixC"; mkdir -p "$FIXC"
cat > "$FIXC/issues.json" <<J
[
  {"number":402,"title":"docs(x): tweak","body":"x","labels":[{"name":"priority/P2"},{"name":"docs-only"}],"createdAt":"$CREATED_48H"}
]
J
outC=$(run_helper "$FIXC" 2>&1)
shortlistC=$(echo "$outC" | tail -n 1)
if [ -f "$shortlistC" ]; then
  rowC=$(jq -c '.missing_label_candidates[] | select(.issue == 402)' "$shortlistC" 2>/dev/null || echo "")
  if [ -z "$rowC" ]; then
    pass_msg "scenario C: docs-only+priority issue still NOT flagged"
  else
    fail_msg "scenario C: docs-only behaviour regressed (row='$rowC')"
  fi
fi

# --- Scenario D: regression — multi-task still counts as path ---
inc_scenario "Scenario D: multi-task still a valid path label (regression guard)"
FIXD="$TMP/fixD"; mkdir -p "$FIXD"
cat > "$FIXD/issues.json" <<J
[
  {"number":403,"title":"feat(x): big","body":"x","labels":[{"name":"priority/P1"},{"name":"multi-task"}],"createdAt":"$CREATED_48H"}
]
J
outD=$(run_helper "$FIXD" 2>&1)
shortlistD=$(echo "$outD" | tail -n 1)
if [ -f "$shortlistD" ]; then
  rowD=$(jq -c '.missing_label_candidates[] | select(.issue == 403)' "$shortlistD" 2>/dev/null || echo "")
  if [ -z "$rowD" ]; then
    pass_msg "scenario D: multi-task+priority issue still NOT flagged"
  else
    fail_msg "scenario D: multi-task behaviour regressed (row='$rowD')"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
