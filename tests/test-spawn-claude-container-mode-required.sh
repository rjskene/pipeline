#!/bin/bash
set -uo pipefail

# Tests for the --container-mode-required enforcement added to spawn-claude.sh
# (issue #238). When PIPELINE_EVAL_CLASSIFIER is set AND the operator launches
# evaluate-issue-pr WITHOUT --container-mode=<name>, spawn-claude re-invokes the
# classifier; if it would emit a --container-mode token, exit 5 instead of
# silently running the bare-host evaluator.
#
# Runs spawn-claude.sh with PIPELINE_SPAWN_DRY_RUN=1 in a temp project tree,
# with `gh` stubbed so no network is required. Follows the pattern of
# test-spawn-claude-container-mode.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"
INVOKE_UNDER_TEST="$SCRIPT_DIR/../mock-web-eval/scripts/eval-classifier-invoke.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi
if [ ! -f "$INVOKE_UNDER_TEST" ]; then
  echo "ERROR: eval-classifier-invoke.sh not found at $INVOKE_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---- Build a "baseline" project tree: classifier present and emits container-mode ----
PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/scripts" "$PROJ/scripts" "$PROJ/mock-web-eval/scripts" "$PROJ/worktree"
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ/.claude/scripts/spawn-claude.sh"
cp "$INVOKE_UNDER_TEST" "$PROJ/mock-web-eval/scripts/eval-classifier-invoke.sh"
chmod +x "$PROJ/mock-web-eval/scripts/eval-classifier-invoke.sh"

cat > "$PROJ/scripts/stub-classifier.sh" <<'EOF'
#!/bin/bash
echo "--container-mode=web-eval"
exit 0
EOF
chmod +x "$PROJ/scripts/stub-classifier.sh"

cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_WIN_TEMP=""
PIPELINE_PATH_A_SKILLS_EXECUTE=""
PIPELINE_PATH_B_SKILLS_EXECUTE=""
PIPELINE_PATH_C_SKILLS_EXECUTE=""
PIPELINE_PATH_A_REVIEWER_EXECUTE=""
PIPELINE_PATH_B_REVIEWER_EXECUTE=""
PIPELINE_PATH_C_REVIEWER_EXECUTE=""
PIPELINE_EVAL_CONTAINERS="web-eval"
PIPELINE_EVAL_CONTAINER_web_eval_COMPOSE_FILE="compose.web-eval.yml"
PIPELINE_EVAL_CONTAINER_web_eval_ENV_FILE=".env.web-eval"
PIPELINE_EVAL_CONTAINER_web_eval_SERVICE="claude-web-eval"
PIPELINE_EVAL_CLASSIFIER="scripts/stub-classifier.sh"
EOF

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$STUB_DIR/gh"
cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
echo "STUB_DOCKER $*"
EOF
chmod +x "$STUB_DIR/docker"

RUNS_LOG="$WORKDIR/runs.log"

# ---- Test 1: classifier wants container, no flag -> exit 5 ----
echo "Test 1: classifier emits --container-mode, flag absent -> exit 5"
inc
OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr \
    "$PROJ/worktree" 200 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "5" ]; then
  fail_msg "expected RC=5 (enforcement triggered), got RC=$RC"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif ! echo "$OUT" | grep -q "classifier wants container dispatch but --container-mode not passed"; then
  fail_msg "missing expected stderr phrase about classifier wanting container dispatch"
  echo "$OUT" | tail -25 | sed 's/^/    /'
elif ! echo "$OUT" | grep -q "eval-classifier-invoke.sh"; then
  fail_msg "stderr should reference eval-classifier-invoke.sh as actionable command"
  echo "$OUT" | tail -25 | sed 's/^/    /'
else
  pass_msg "exit 5 with actionable stderr"
fi

# ---- Test 2: classifier wants container BUT flag present -> normal dispatch ----
echo "Test 2: classifier emits --container-mode, flag present -> normal dispatch"
inc
OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=web-eval \
    "$PROJ/worktree" 201 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0 (flag satisfies guard), got RC=$RC"
  echo "$OUT" | tail -15 | sed 's/^/    /'
elif echo "$OUT" | grep -q "classifier wants container dispatch"; then
  fail_msg "enforcement stderr unexpectedly emitted when flag is present"
else
  pass_msg "flag-present passthrough"
fi

# ---- Test 3: classifier emits nothing -> normal dispatch ----
echo "Test 3: classifier emits nothing -> normal dispatch (no enforcement)"
inc
PROJ3="$WORKDIR/proj3"
mkdir -p "$PROJ3/.claude/scripts" "$PROJ3/scripts" "$PROJ3/mock-web-eval/scripts" "$PROJ3/worktree"
cp "$SCRIPT_UNDER_TEST" "$PROJ3/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ3/.claude/scripts/spawn-claude.sh"
cp "$INVOKE_UNDER_TEST" "$PROJ3/mock-web-eval/scripts/eval-classifier-invoke.sh"
chmod +x "$PROJ3/mock-web-eval/scripts/eval-classifier-invoke.sh"
cat > "$PROJ3/scripts/stub-classifier-empty.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$PROJ3/scripts/stub-classifier-empty.sh"
cp "$PROJ/pipeline.config" "$PROJ3/pipeline.config"
sed -i 's|PIPELINE_EVAL_CLASSIFIER=.*|PIPELINE_EVAL_CLASSIFIER="scripts/stub-classifier-empty.sh"|' "$PROJ3/pipeline.config"
OUT=$(cd "$PROJ3" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr \
    "$PROJ3/worktree" 202 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0 (classifier said no container needed), got RC=$RC"
  echo "$OUT" | tail -15 | sed 's/^/    /'
elif echo "$OUT" | grep -q "classifier wants container dispatch"; then
  fail_msg "enforcement stderr unexpectedly emitted when classifier emits nothing"
else
  pass_msg "classifier-emits-nothing passthrough"
fi

# ---- Test 4: PIPELINE_EVAL_CLASSIFIER unset -> normal dispatch ----
echo "Test 4: PIPELINE_EVAL_CLASSIFIER unset -> normal dispatch (no enforcement)"
inc
PROJ4="$WORKDIR/proj4"
mkdir -p "$PROJ4/.claude/scripts" "$PROJ4/scripts" "$PROJ4/mock-web-eval/scripts" "$PROJ4/worktree"
cp "$SCRIPT_UNDER_TEST" "$PROJ4/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ4/.claude/scripts/spawn-claude.sh"
cp "$INVOKE_UNDER_TEST" "$PROJ4/mock-web-eval/scripts/eval-classifier-invoke.sh"
chmod +x "$PROJ4/mock-web-eval/scripts/eval-classifier-invoke.sh"
grep -v "PIPELINE_EVAL_CLASSIFIER" "$PROJ/pipeline.config" > "$PROJ4/pipeline.config"
OUT=$(cd "$PROJ4" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr \
    "$PROJ4/worktree" 203 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0 (classifier unset, enforcement skipped), got RC=$RC"
  echo "$OUT" | tail -15 | sed 's/^/    /'
elif echo "$OUT" | grep -q "classifier wants container dispatch"; then
  fail_msg "enforcement stderr unexpectedly emitted when PIPELINE_EVAL_CLASSIFIER is unset"
else
  pass_msg "PIPELINE_EVAL_CLASSIFIER-unset passthrough"
fi

# ---- Test 5: skill != evaluate-issue-pr -> enforcement skipped ----
echo "Test 5: skill != evaluate-issue-pr -> enforcement skipped"
inc
OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill execute-issue-plan \
    "$PROJ/worktree" 204 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0 (skill != evaluate-issue-pr, enforcement skipped), got RC=$RC"
  echo "$OUT" | tail -15 | sed 's/^/    /'
elif echo "$OUT" | grep -q "classifier wants container dispatch"; then
  fail_msg "enforcement stderr unexpectedly emitted for execute-issue-plan"
else
  pass_msg "non-evaluate-pr-skill passthrough"
fi

# ---- Test 6: eval-classifier-invoke.sh missing -> enforcement skipped (degrade open) ----
echo "Test 6: eval-classifier-invoke.sh missing -> enforcement skipped"
inc
PROJ6="$WORKDIR/proj6"
mkdir -p "$PROJ6/.claude/scripts" "$PROJ6/scripts" "$PROJ6/worktree"
cp "$SCRIPT_UNDER_TEST" "$PROJ6/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ6/.claude/scripts/spawn-claude.sh"
# NOTE: intentionally do NOT copy eval-classifier-invoke.sh
cp "$PROJ/scripts/stub-classifier.sh" "$PROJ6/scripts/stub-classifier.sh"
chmod +x "$PROJ6/scripts/stub-classifier.sh"
cp "$PROJ/pipeline.config" "$PROJ6/pipeline.config"
OUT=$(cd "$PROJ6" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr \
    "$PROJ6/worktree" 205 slug tmux 2>&1 ; echo "RC=$?") || true
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0 (classifier-invoke missing -> degrade open), got RC=$RC"
  echo "$OUT" | tail -15 | sed 's/^/    /'
elif echo "$OUT" | grep -q "classifier wants container dispatch"; then
  fail_msg "enforcement stderr unexpectedly emitted when eval-classifier-invoke.sh is missing"
else
  pass_msg "missing-classifier-invoke degrade-open passthrough"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
