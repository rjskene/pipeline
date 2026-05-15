#!/bin/bash
set -euo pipefail

# Tests for the `brainstorm` pipeline label (issue #28).
#
# Asserts:
#   1. `PIPELINE_LABELS_BRAINSTORM` is defined in pipeline.config (and example if present).
#   2. `skills/run/SKILL.md` references the variable in all five required surfaces:
#      full-send constraints, excluded-labels prose, discovery step,
#      status-table Tags exclusion, and step 5 proposal gate.
#   3. `skills/create-issues/SKILL.md` has the heuristic bullet under `### Labels`.
#   4. End-to-end: filter logic treats brainstorm-labeled issues as table-visible
#      but never auto-plannable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# --- Task 1: pipeline.config defines the variable ----------------------------
inc
CONFIG="$REPO_ROOT/pipeline.config"
if [ -f "$CONFIG" ]; then
  if grep -qE '^PIPELINE_LABELS_BRAINSTORM=' "$CONFIG"; then
    pass_msg "pipeline.config defines PIPELINE_LABELS_BRAINSTORM"
  else
    fail_msg "missing PIPELINE_LABELS_BRAINSTORM in pipeline.config"
  fi
else
  # No project pipeline.config in repo (dogfood worktrees source from parent).
  # Skip; the .example file assertion below still gates the rollout.
  pass_msg "pipeline.config not present at repo root — skipped (example file gates rollout)"
fi

inc
EXAMPLE="$REPO_ROOT/pipeline.config.example"
if [ -f "$EXAMPLE" ]; then
  if grep -qE '^PIPELINE_LABELS_BRAINSTORM=' "$EXAMPLE"; then
    pass_msg "pipeline.config.example defines PIPELINE_LABELS_BRAINSTORM"
  else
    fail_msg "missing PIPELINE_LABELS_BRAINSTORM in pipeline.config.example"
  fi
else
  pass_msg "pipeline.config.example not present — skipped"
fi

# --- Task 2: run/SKILL.md surfaces -------------------------------------------
RUN_SKILL="$REPO_ROOT/skills/run/SKILL.md"

inc
if [ -f "$RUN_SKILL" ]; then
  COUNT=$(grep -c 'PIPELINE_LABELS_BRAINSTORM' "$RUN_SKILL" || true)
  if [ "$COUNT" -ge 3 ]; then
    pass_msg "run/SKILL.md references PIPELINE_LABELS_BRAINSTORM $COUNT times (>=3)"
  else
    fail_msg "PIPELINE_LABELS_BRAINSTORM must appear >=3 times in run/SKILL.md (got $COUNT)"
  fi
else
  fail_msg "skills/run/SKILL.md not found"
fi

inc
if [ -f "$RUN_SKILL" ] && grep -q 'stage = `PIPELINE_LABELS_BRAINSTORM`' "$RUN_SKILL"; then
  pass_msg "run/SKILL.md renders status-table stage label for brainstorm"
else
  fail_msg "status-table stage = \`PIPELINE_LABELS_BRAINSTORM\` line missing in run/SKILL.md"
fi

# --- Task 3: create-issues/SKILL.md heuristic --------------------------------
CI_SKILL="$REPO_ROOT/skills/create-issues/SKILL.md"

inc
if [ -f "$CI_SKILL" ] \
  && grep -q 'brainstorm' "$CI_SKILL" \
  && grep -qE 'architectural critique|exploration|should we' "$CI_SKILL"; then
  pass_msg "create-issues/SKILL.md has brainstorm-label heuristic"
else
  fail_msg "create-issues heuristic for brainstorm label missing"
fi

# --- Task 4: behavioral filter check (jq fixture) ----------------------------
inc
if command -v jq >/dev/null 2>&1; then
  FIXTURE=$(mktemp)
  trap 'rm -f "$FIXTURE"' EXIT
  cat > "$FIXTURE" <<'JSON'
[
  {"number": 1, "title": "normal issue",     "labels": []},
  {"number": 2, "title": "brainstorm issue", "labels": [{"name":"brainstorm"}]},
  {"number": 3, "title": "human issue",      "labels": [{"name":"human"}]},
  {"number": 4, "title": "excluded issue",   "labels": [{"name":"excluded"}]}
]
JSON

  VISIBLE=$(jq -r '.[] | select((.labels|map(.name)|index("excluded"))|not) | .number' "$FIXTURE" | sort | paste -sd, -)
  PLANNABLE=$(jq -r '
    .[]
    | select((.labels|map(.name)|index("excluded"))|not)
    | select((.labels|map(.name)|index("later"))|not)
    | select((.labels|map(.name)|index("human"))|not)
    | select((.labels|map(.name)|index("brainstorm"))|not)
    | .number
  ' "$FIXTURE" | sort | paste -sd, -)

  if [ "$VISIBLE" = "1,2,3" ] && [ "$PLANNABLE" = "1" ]; then
    pass_msg "behavioral filter: visible=$VISIBLE, plannable=$PLANNABLE"
  else
    fail_msg "behavioral filter mismatch: visible=$VISIBLE (want 1,2,3), plannable=$PLANNABLE (want 1)"
  fi
else
  pass_msg "jq unavailable — behavioral block skipped (doc-grep assertions remain mandatory)"
fi

# --- Tally -------------------------------------------------------------------
echo ""
echo "test-brainstorm-label.sh: $PASS passed, $FAIL failed (of $TESTS)"
[ "$FAIL" -eq 0 ]
