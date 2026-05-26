#!/bin/bash
set -uo pipefail

# Tests the PIPELINE_CONTAINER_SKILLS allowlist gate added by issue #321 to
# scripts/spawn-claude.sh. Five orthogonal cases (unset default, default
# allows evaluate-issue-pr, explicit opt-in, plan-issue rejected,
# empty-string disables all) — codifies the behavior so future edits to the
# allowlist logic trip immediately.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"

COUNT=0
FAILS=0

pass_msg() { echo "  PASS: $1"; }
fail_msg() { echo "  FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
inc()      { COUNT=$((COUNT + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/scripts"
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ/.claude/scripts/spawn-claude.sh"

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
EOF

mkdir -p "$PROJ/worktree"

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

# run_case <skill> <env-spec> <issue>
# env-spec: "unset" -> don't pass PIPELINE_CONTAINER_SKILLS;
#           anything else is the literal value (including "" for explicit empty).
# Echoes the merged stdout+stderr followed by a trailing "RC=<rc>" line.
run_case() {
  local skill="$1" envspec="$2" issue="$3"
  if [ "$envspec" = "unset" ]; then
    (cd "$PROJ" && \
      PATH="$STUB_DIR:$PATH" \
      STUB_LABELS="" \
      PIPELINE_SPAWN_DRY_RUN=1 \
      PIPELINE_LOGS_ENABLED=true \
      PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
      PIPELINE_EVAL_ISOLATION=container \
      bash .claude/scripts/spawn-claude.sh \
        --skill "$skill" --container-mode=web-eval \
        "$PROJ/worktree" "$issue" slug tmux 2>&1
      echo "RC=$?")
  else
    (cd "$PROJ" && \
      PATH="$STUB_DIR:$PATH" \
      STUB_LABELS="" \
      PIPELINE_SPAWN_DRY_RUN=1 \
      PIPELINE_LOGS_ENABLED=true \
      PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
      PIPELINE_EVAL_ISOLATION=container \
      PIPELINE_CONTAINER_SKILLS="$envspec" \
      bash .claude/scripts/spawn-claude.sh \
        --skill "$skill" --container-mode=web-eval \
        "$PROJ/worktree" "$issue" slug tmux 2>&1
      echo "RC=$?")
  fi
}

# -------------------------------------------------------------------------
# Case 1: PIPELINE_CONTAINER_SKILLS unset + execute-issue-plan -> exit 4
# -------------------------------------------------------------------------
echo "Case 1: unset PIPELINE_CONTAINER_SKILLS + execute-issue-plan rejected"
inc
OUT="$(run_case execute-issue-plan unset 201)"
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "4" ]; then
  fail_msg "expected RC=4, got RC=$RC"
elif ! echo "$OUT" | grep -q "container-mode rejected: skill 'execute-issue-plan' not in PIPELINE_CONTAINER_SKILLS allowlist (current: evaluate-issue-pr)"; then
  fail_msg "missing expected allowlist-rejection stderr with default current=evaluate-issue-pr"
  echo "$OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "RC=4 + correct allowlist-rejection stderr (default current=evaluate-issue-pr)"
fi

# -------------------------------------------------------------------------
# Case 2: PIPELINE_CONTAINER_SKILLS unset + evaluate-issue-pr -> exit 0,
# DOCKER_PREFIX present (default allowlist permits evaluate-issue-pr)
# -------------------------------------------------------------------------
echo "Case 2: unset PIPELINE_CONTAINER_SKILLS + evaluate-issue-pr accepted (default)"
inc
OUT="$(run_case evaluate-issue-pr unset 202)"
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0, got RC=$RC"
elif ! echo "$OUT" | grep -qE '^DOCKER_PREFIX='; then
  fail_msg "missing DOCKER_PREFIX= line in dry-run output"
  echo "$OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "RC=0 + DOCKER_PREFIX emitted (default allowlist allowed evaluate-issue-pr)"
fi

# -------------------------------------------------------------------------
# Case 3: explicit opt-in lets execute-issue-plan through
# -------------------------------------------------------------------------
echo "Case 3: PIPELINE_CONTAINER_SKILLS includes execute-issue-plan -> accepted"
inc
OUT="$(run_case execute-issue-plan "evaluate-issue-pr execute-issue-plan" 203)"
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "0" ]; then
  fail_msg "expected RC=0, got RC=$RC"
elif ! echo "$OUT" | grep -qE '^DOCKER_PREFIX='; then
  fail_msg "missing DOCKER_PREFIX= line in dry-run output"
  echo "$OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "RC=0 + DOCKER_PREFIX emitted (opt-in via allowlist)"
fi

# -------------------------------------------------------------------------
# Case 4: skill outside an explicit allowlist is rejected with current=<list>
# -------------------------------------------------------------------------
echo "Case 4: PIPELINE_CONTAINER_SKILLS=\"evaluate-issue-pr\" + plan-issue rejected"
inc
OUT="$(run_case plan-issue "evaluate-issue-pr" 204)"
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "4" ]; then
  fail_msg "expected RC=4, got RC=$RC"
elif ! echo "$OUT" | grep -q "not in PIPELINE_CONTAINER_SKILLS allowlist (current: evaluate-issue-pr)"; then
  fail_msg "missing expected allowlist-rejection stderr 'current: evaluate-issue-pr'"
  echo "$OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "RC=4 + correct allowlist-rejection stderr (current: evaluate-issue-pr)"
fi

# -------------------------------------------------------------------------
# Case 5: explicit empty string disables ALL skills (even evaluate-issue-pr)
# -------------------------------------------------------------------------
echo "Case 5: PIPELINE_CONTAINER_SKILLS=\"\" disables all (evaluate-issue-pr rejected)"
inc
OUT="$(run_case evaluate-issue-pr "" 205)"
RC=$(echo "$OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$RC" != "4" ]; then
  fail_msg "expected RC=4, got RC=$RC"
elif ! echo "$OUT" | grep -q "not in PIPELINE_CONTAINER_SKILLS allowlist (current: )"; then
  fail_msg "missing expected stderr 'current: ' (empty list)"
  echo "$OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "RC=4 + correct empty-list rejection stderr"
fi

echo ""
echo "================================"
echo "  $COUNT tests: FAIL=$FAILS"
echo "================================"

if [ "$FAILS" = "0" ]; then
  echo "OK: $COUNT tests passed"
  exit 0
else
  echo "FAIL: $FAILS of $COUNT tests"
  exit 1
fi
