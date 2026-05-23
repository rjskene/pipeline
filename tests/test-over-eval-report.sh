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
cat > "$FIX2/pr-101.json" <<'J'
{"number":101,"additions":3,"deletions":1,"comments":[]}
J
cat > "$FIX2/pr-102.json" <<'J'
{"number":102,"additions":120,"deletions":40,"comments":[
  {"author":{"login":"rjskene"},"body":"## Evaluation\n\n**Verdict:** Approve\n\nLooks good. Tests pass. Coverage adequate.\n","createdAt":"2026-05-11T11:00:00Z"}
]}
J
cat > "$FIX2/pr-103.json" <<'J'
{"number":103,"additions":500,"deletions":300,"comments":[
  {"author":{"login":"rjskene"},"body":"## Evaluation\n\n**Verdict:** Approve\n\nThorough review:\n- Each task ran tdd-implementer.\n- Diff matches plan.\n- No scope creep.\n","createdAt":"2026-05-12T12:00:00Z"}
]}
J
cat > "$FIX2/pr-104.json" <<'J'
{"number":104,"additions":2,"deletions":1,"comments":[
  {"author":{"login":"rjskene"},"body":"## Evaluation\n\nLGTM\n","createdAt":"2026-05-13T11:00:00Z"}
]}
J

# Linked-issue fixtures (## Implementation Plan + optional ## Plan Evaluation
# live on the issue; PATH label lives in the issue labels).
cat > "$FIX2/issue-201.json" <<'J'
{"number":201,"labels":[{"name":"docs-only"}],"comments":[
  {"body":"## Implementation Plan\n\n**Files to change:**\n- README.md\n**Tasks (ordered):**\n- Task 1: fix typo.\n","createdAt":"2026-05-10T09:00:00Z"}
]}
J
cat > "$FIX2/issue-202.json" <<'J'
{"number":202,"labels":[],"comments":[
  {"body":"## Implementation Plan\n\n**Files to change:**\n- src/api.ts\n- tests/test-api.ts\n\n**Tasks (ordered):**\n- Task 0: invoke superpowers:test-driven-development.\n- Task 1: scaffold endpoint test.\n- Task 2: implement endpoint.\n- Task 3: integration test.\n","createdAt":"2026-05-11T08:00:00Z"},
  {"body":"## Plan Evaluation\n\n**Verdict:** Approve\n\n**File accuracy:** matches.\n**Risks:** none new.\n","createdAt":"2026-05-11T09:00:00Z"}
]}
J
cat > "$FIX2/issue-203.json" <<'J'
{"number":203,"labels":[{"name":"multi-task"}],"comments":[
  {"body":"## Implementation Plan\n\n**Files to change:**\n- src/a.ts\n- src/b.ts\n- src/c.ts\n- tests/a.test.ts\n- tests/b.test.ts\n- tests/c.test.ts\n\n**Tasks (ordered):**\n- Task 0: invoke superpowers:test-driven-development.\n- Task 1: scaffold a.ts (target=src/a.ts).\n- Task 2: scaffold b.ts (target=src/b.ts).\n- Task 3: scaffold c.ts (target=src/c.ts).\n- Task 4: integrate.\n- Task 5: e2e.\n","createdAt":"2026-05-12T08:00:00Z"},
  {"body":"## Plan Evaluation\n\n**Verdict:** Approve\n\n**File accuracy:** all matching.\n**Risks:** scope is wide but isolated by target= sentinels.\n","createdAt":"2026-05-12T09:00:00Z"}
]}
J
cat > "$FIX2/issue-204.json" <<'J'
{"number":204,"labels":[{"name":"quick-fix"}],"comments":[
  {"body":"## Implementation Plan\n\n**Files to change:**\n- src/util.ts\n**Tasks (ordered):**\n- Task 1: fix off-by-one.\n","createdAt":"2026-05-13T08:00:00Z"}
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

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
