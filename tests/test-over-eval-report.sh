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
inc_scenario "Scenario 2: fixture loader walks 4 synthetic PRs (one per PATH)"

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
FIX2="$TMP/fix2"; mkdir -p "$FIX2"

# Four merged PRs, one per PATH (docs-only=A, default=B, multi-task=C, quick-fix=D).
cat > "$FIX2/prs.json" <<'J'
[
  {"number":101,"title":"docs(readme): typo","additions":3,"deletions":1,"body":"Closes #201","mergedAt":"2026-05-10T10:00:00Z"},
  {"number":102,"title":"feat(api): add endpoint","additions":120,"deletions":40,"body":"Closes #202","mergedAt":"2026-05-11T10:00:00Z"},
  {"number":103,"title":"refactor(core): split modules","additions":500,"deletions":300,"body":"Closes #203","mergedAt":"2026-05-12T10:00:00Z"},
  {"number":104,"title":"fix(util): tiny bug","additions":2,"deletions":1,"body":"Closes #204","mergedAt":"2026-05-13T10:00:00Z"}
]
J

# Per-PR comment fixtures (## Evaluation lives on the PR).
# Block line counts are kept deterministic so we can assert exact values.
#
# PR 101 (PATH A): no PR comments     → pr_eval = 0
# PR 102 (PATH B): 3-line ## Evaluation block
# PR 103 (PATH C): 5-line ## Evaluation block
# PR 104 (PATH D): 2-line ## Evaluation block
cat > "$FIX2/pr-101.json" <<'J'
{"number":101,"additions":3,"deletions":1,"comments":[]}
J
cat > "$FIX2/pr-102.json" <<'J'
{"number":102,"additions":120,"deletions":40,"comments":[
  {"author":{"login":"rjskene"},"body":"## Evaluation\nLine 1\nLine 2","createdAt":"2026-05-11T11:00:00Z"}
]}
J
cat > "$FIX2/pr-103.json" <<'J'
{"number":103,"additions":500,"deletions":300,"comments":[
  {"author":{"login":"rjskene"},"body":"## Evaluation\nLine 1\nLine 2\nLine 3\nLine 4","createdAt":"2026-05-12T12:00:00Z"}
]}
J
cat > "$FIX2/pr-104.json" <<'J'
{"number":104,"additions":2,"deletions":1,"comments":[
  {"author":{"login":"rjskene"},"body":"## Evaluation\nLGTM","createdAt":"2026-05-13T11:00:00Z"}
]}
J

# Linked-issue fixtures (## Implementation Plan + optional ## Plan Evaluation
# live on the issue; PATH label lives in the issue labels).
#
# Issue 201 (PATH A): plan = 2 lines, no plan-eval
# Issue 202 (PATH B): plan = 3 lines, plan-eval = 2 lines
# Issue 203 (PATH C): plan = 5 lines, plan-eval = 3 lines
# Issue 204 (PATH D): plan = 2 lines, no plan-eval
cat > "$FIX2/issue-201.json" <<'J'
{"number":201,"labels":[{"name":"docs-only"}],"comments":[
  {"body":"## Implementation Plan\nBody line 1","createdAt":"2026-05-10T09:00:00Z"}
]}
J
cat > "$FIX2/issue-202.json" <<'J'
{"number":202,"labels":[],"comments":[
  {"body":"## Implementation Plan\nBody 1\nBody 2","createdAt":"2026-05-11T08:00:00Z"},
  {"body":"## Plan Evaluation\nEval 1","createdAt":"2026-05-11T09:00:00Z"}
]}
J
cat > "$FIX2/issue-203.json" <<'J'
{"number":203,"labels":[{"name":"multi-task"}],"comments":[
  {"body":"## Implementation Plan\nBody 1\nBody 2\nBody 3\nBody 4","createdAt":"2026-05-12T08:00:00Z"},
  {"body":"## Plan Evaluation\nEval 1\nEval 2","createdAt":"2026-05-12T09:00:00Z"}
]}
J
cat > "$FIX2/issue-204.json" <<'J'
{"number":204,"labels":[{"name":"quick-fix"}],"comments":[
  {"body":"## Implementation Plan\nBody line 1","createdAt":"2026-05-13T08:00:00Z"}
]}
J

ROWS_OUT="$(bash "$HELPER" --fixture "$FIX2" --emit-rows-json 2>/dev/null || true)"
ROWS_RC=$?
if [ "$ROWS_RC" -eq 0 ]; then
  pass_msg "fixture-mode run exits 0"
else
  fail_msg "fixture-mode run exited non-zero (rc=$ROWS_RC)"
fi

N_ROWS="$(printf '%s' "$ROWS_OUT" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$N_ROWS" = "4" ]; then
  pass_msg "fixture-mode emits exactly 4 PR rows"
else
  fail_msg "expected 4 PR rows, got $N_ROWS"
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

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
