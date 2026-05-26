#!/bin/bash
set -uo pipefail

# Regression test for issue #269: the env-file write-path (probe) and the
# spawn-claude resolution-path must agree. The probe
# (mock-web-eval-probe-port.sh) writes the env file under PIPELINE_WORKTREE_PATH
# so concurrent worktrees don't race on a shared file; spawn-claude must
# resolve a relative ENV_FILE against the same WORKTREE_PATH (not REPO_ROOT).
#
# Behaviors under test:
#   (a) A relative ENV_FILE resolves to absolute against WORKTREE_PATH BEFORE
#       DOCKER_PREFIX is assembled, so the file the probe just wrote at
#       <WORKTREE_PATH>/<rel-path> is the same file --env-file points at.
#   (b) An already-absolute ENV_FILE is still passed through verbatim
#       (regression guard against accidentally always-prefixing).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"

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
PIPELINE_EVAL_CONTAINERS="mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_COMPOSE_FILE="mock-web-eval/docker/compose.yml"
PIPELINE_EVAL_CONTAINER_mock_web_eval_ENV_FILE="mock-web-eval/target/.env.mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_SERVICE="claude-mock-web-eval"
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

# -------------------------------------------------------------------------
# Test (a): probe-writer ↔ spawn-claude-reader alignment under WORKTREE_PATH.
#
# The PREFLIGHT_CMD mimics what mock-web-eval-probe-port.sh does: write the
# env file under $PIPELINE_WORKTREE_PATH. After spawn-claude assembles the
# DOCKER_PREFIX, the --env-file token MUST point at the same file the probe
# just wrote — i.e. resolved against WORKTREE_PATH, not REPO_ROOT. The
# existence check on the resolved path is load-bearing: it's the assertion
# that catches the alignment bug regardless of which absolute prefix the
# resolver chose.
# -------------------------------------------------------------------------
echo "Test (a): probe writes under WORKTREE_PATH; spawn-claude resolves --env-file there"
inc
PRE_SNIPPET='mkdir -p "$PIPELINE_WORKTREE_PATH/mock-web-eval/target" && touch "$PIPELINE_WORKTREE_PATH/mock-web-eval/target/.env.mock-web-eval"'
OUT_A=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  PIPELINE_EVAL_ISOLATION=container \
  PIPELINE_EVAL_CONTAINER_mock_web_eval_PREFLIGHT_CMD="$PRE_SNIPPET" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=mock-web-eval \
    "$PROJ/worktree" 269 slug tmux 2>&1 || true)
DOCKER_LINE_A=$(echo "$OUT_A" | grep -E '^DOCKER_PREFIX=' || true)
EXPECTED_A="$PROJ/worktree/mock-web-eval/target/.env.mock-web-eval"
if [ -z "$DOCKER_LINE_A" ]; then
  fail_msg "Test (a): no DOCKER_PREFIX= line in dry-run output"
  echo "$OUT_A" | tail -10 | sed 's/^/    /'
elif ! echo "$DOCKER_LINE_A" | grep -q -- "--env-file $EXPECTED_A"; then
  fail_msg "Test (a): DOCKER_PREFIX missing '--env-file $EXPECTED_A'"
  echo "  Got: $DOCKER_LINE_A"
else
  # Pull the resolved --env-file path token out of DOCKER_PREFIX and verify
  # the file actually exists on disk. This is the alignment assertion: the
  # probe wrote to $PIPELINE_WORKTREE_PATH/..., spawn-claude must resolve to
  # the same path.
  resolved=$(echo "$DOCKER_LINE_A" | grep -oE -- '--env-file [^ ]+' | awk '{print $2}')
  if [ ! -f "$resolved" ]; then
    fail_msg "Test (a): resolved --env-file path '$resolved' does not exist on disk (probe wrote at $EXPECTED_A)"
  else
    pass_msg "Test (a): DOCKER_PREFIX --env-file resolves to $EXPECTED_A and the file exists"
  fi
fi

# -------------------------------------------------------------------------
# Test (b): absolute ENV_FILE preserved verbatim (no WORKTREE_PATH prefix).
# Regression guard: the fix must not always-prefix; absolute paths win.
# -------------------------------------------------------------------------
echo "Test (b): absolute ENV_FILE preserved verbatim (no WORKTREE_PATH prefix)"
inc
PROJ_B="$WORKDIR/proj-b"
mkdir -p "$PROJ_B/.claude/scripts" "$PROJ_B/worktree"
cp "$SCRIPT_UNDER_TEST" "$PROJ_B/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ_B/.claude/scripts/spawn-claude.sh"
cat > "$PROJ_B/pipeline.config" <<'EOF'
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
PIPELINE_EVAL_CONTAINERS="mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_COMPOSE_FILE="mock-web-eval/docker/compose.yml"
PIPELINE_EVAL_CONTAINER_mock_web_eval_ENV_FILE="/tmp/abs.env"
PIPELINE_EVAL_CONTAINER_mock_web_eval_SERVICE="claude-mock-web-eval"
EOF
OUT_B=$(cd "$PROJ_B" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  PIPELINE_EVAL_ISOLATION=container \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=mock-web-eval \
    "$PROJ_B/worktree" 270 slug tmux 2>&1 || true)
DOCKER_LINE_B=$(echo "$OUT_B" | grep -E '^DOCKER_PREFIX=' || true)
if [ -z "$DOCKER_LINE_B" ]; then
  fail_msg "Test (b): no DOCKER_PREFIX= line in dry-run output"
elif ! echo "$DOCKER_LINE_B" | grep -q -- "--env-file /tmp/abs.env"; then
  fail_msg "Test (b): DOCKER_PREFIX missing '--env-file /tmp/abs.env'"
  echo "  Got: $DOCKER_LINE_B"
elif echo "$DOCKER_LINE_B" | grep -q -- "--env-file $PROJ_B/worktree/tmp/abs.env"; then
  fail_msg "Test (b): DOCKER_PREFIX has double-prefix $PROJ_B/worktree/tmp/abs.env"
  echo "  Got: $DOCKER_LINE_B"
else
  pass_msg "Test (b): DOCKER_PREFIX preserves absolute --env-file /tmp/abs.env"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
