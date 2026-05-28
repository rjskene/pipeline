#!/bin/bash
set -euo pipefail

# Tests that spawn-claude.sh records the requested model on its gated
# runs.log append (issue #577). Verifies:
#   - When PIPELINE_LOGS_ENABLED=true and MODEL=<id> is exported, the
#     appended runs.log line contains a trailing `\tmodel=<id>` field.
#   - The MODEL column is empty (model= with no value) when MODEL is unset
#     — backward-compatible for older callers that don't pass a model.
#   - When PIPELINE_LOGS_ENABLED is unset/false, NO runs.log is written
#     (gating contract preserved; this PR rides the already-gated write).
#
# Follows the substrate of test-spawn-claude-runs-log.sh: dry-run mode,
# stub gh on PATH, PIPELINE_RUNS_LOG_OVERRIDE to redirect the append.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/worktree"

cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_WIN_TEMP=""
PIPELINE_PATH_A_SKILLS_EXECUTE=""
PIPELINE_PATH_B_SKILLS_EXECUTE=""
PIPELINE_PATH_C_SKILLS_EXECUTE=""
PIPELINE_PATH_D_SKILLS_EXECUTE=""
PIPELINE_PATH_A_REVIEWER_EXECUTE=""
PIPELINE_PATH_B_REVIEWER_EXECUTE=""
PIPELINE_PATH_C_REVIEWER_EXECUTE=""
PIPELINE_PATH_D_REVIEWER_EXECUTE=""
EOF

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
# Empty label list — drives PATH B (default).
exit 0
EOF
chmod +x "$STUB_DIR/gh"

RUNS_LOG="$WORKDIR/runs.log"

# --------------------------------------------------------------------------
# Test 1: MODEL env populates the new trailing model= column when logs on
# --------------------------------------------------------------------------
echo "Test 1: MODEL=claude-opus-4-7 emits trailing model=claude-opus-4-7"
inc
: > "$RUNS_LOG"
cd "$PROJ"
PATH="$STUB_DIR:$PATH" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  MODEL="claude-opus-4-7" \
  bash "$SCRIPT_UNDER_TEST" "$PROJ/worktree" 910 slug tmux >/dev/null 2>&1
cd - >/dev/null

if [ ! -f "$RUNS_LOG" ]; then
  fail_msg "runs.log not created at $RUNS_LOG"
else
  LINE=$(tail -1 "$RUNS_LOG")
  if echo "$LINE" | grep -q $'\tmodel=claude-opus-4-7$'; then
    pass_msg "trailing model=claude-opus-4-7 present: $LINE"
  else
    fail_msg "trailing model= column missing or wrong: $LINE"
  fi
fi

# --------------------------------------------------------------------------
# Test 2: backward-compat — unset MODEL emits empty model= (no value)
# --------------------------------------------------------------------------
echo "Test 2: MODEL unset -> trailing model= (empty value, backward-compat)"
inc
: > "$RUNS_LOG"
cd "$PROJ"
# Strip any inherited MODEL from the parent shell.
PATH="$STUB_DIR:$PATH" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  env -u MODEL bash "$SCRIPT_UNDER_TEST" "$PROJ/worktree" 911 slug tmux >/dev/null 2>&1
cd - >/dev/null

if [ ! -f "$RUNS_LOG" ]; then
  fail_msg "runs.log not created at $RUNS_LOG"
else
  LINE=$(tail -1 "$RUNS_LOG")
  if echo "$LINE" | grep -q $'\tmodel=$'; then
    pass_msg "empty model= column present (backward-compat): $LINE"
  else
    fail_msg "expected empty trailing model= column, got: $LINE"
  fi
fi

# --------------------------------------------------------------------------
# Test 3: gating contract — PIPELINE_LOGS_ENABLED=false -> no runs.log write
# --------------------------------------------------------------------------
echo "Test 3: PIPELINE_LOGS_ENABLED=false suppresses runs.log even with MODEL set"
inc
GATED_LOG="$WORKDIR/gated-runs.log"
rm -f "$GATED_LOG"
cd "$PROJ"
PATH="$STUB_DIR:$PATH" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=false \
  PIPELINE_RUNS_LOG_OVERRIDE="$GATED_LOG" \
  MODEL="claude-opus-4-7" \
  bash "$SCRIPT_UNDER_TEST" "$PROJ/worktree" 912 slug tmux >/dev/null 2>&1
cd - >/dev/null

if [ -e "$GATED_LOG" ]; then
  fail_msg "runs.log was created despite PIPELINE_LOGS_ENABLED=false"
else
  pass_msg "no runs.log write when PIPELINE_LOGS_ENABLED=false (gating preserved)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
