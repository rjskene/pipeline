#!/bin/bash
set -uo pipefail

# Tests that --manual-merge propagates into the containerized evaluator
# (issue #257 Bug 2). When --container-mode=<name> AND --manual-merge are
# both passed to spawn-claude.sh, the DOCKER_PREFIX must include
# `-e MANUAL_MERGE=1` BEFORE the service token, so docker-compose threads
# the env var into the in-container claude session rather than treating
# it as a positional arg to the service.
#
# Mirrors the harness pattern in test-spawn-claude-container-mode.sh.

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

run_spawn() {
  # Args: <issue> [extra spawn-claude args...]
  local issue="$1"; shift
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    PIPELINE_LOGS_ENABLED=true \
    PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
    bash .claude/scripts/spawn-claude.sh \
      --skill evaluate-issue-pr --container-mode=web-eval "$@" \
      "$PROJ/worktree" "$issue" slug tmux \
      2>"$WORKDIR/last.err" || true
  cd - >/dev/null
}

# -------------------------------------------------------------------------
# Test 1 (positive): --manual-merge present -> DOCKER_PREFIX has -e MANUAL_MERGE=1
# -------------------------------------------------------------------------
echo "Test 1: --manual-merge + --container-mode -> -e MANUAL_MERGE=1 in DOCKER_PREFIX"
inc
OUT="$(run_spawn 200 --manual-merge)"
DOCKER_LINE=$(echo "$OUT" | grep -E '^DOCKER_PREFIX=' || true)
if [ -z "$DOCKER_LINE" ]; then
  fail_msg "no DOCKER_PREFIX= line in dry-run output"
  echo "$OUT" | sed 's/^/    /'
elif ! echo "$DOCKER_LINE" | grep -q -- "-e MANUAL_MERGE=1"; then
  fail_msg "DOCKER_PREFIX missing '-e MANUAL_MERGE=1'"
  echo "    $DOCKER_LINE"
else
  pass_msg "DOCKER_PREFIX contains '-e MANUAL_MERGE=1'"
fi

# -------------------------------------------------------------------------
# Test 2 (negative): no --manual-merge -> DOCKER_PREFIX has no MANUAL_MERGE token
# -------------------------------------------------------------------------
echo "Test 2: no --manual-merge -> DOCKER_PREFIX has no MANUAL_MERGE substring"
inc
OUT2="$(run_spawn 201)"
DOCKER_LINE2=$(echo "$OUT2" | grep -E '^DOCKER_PREFIX=' || true)
if [ -z "$DOCKER_LINE2" ]; then
  fail_msg "no DOCKER_PREFIX= line in dry-run output (negative case)"
  echo "$OUT2" | sed 's/^/    /'
elif echo "$DOCKER_LINE2" | grep -q "MANUAL_MERGE"; then
  fail_msg "DOCKER_PREFIX should NOT contain MANUAL_MERGE but did:"
  echo "    $DOCKER_LINE2"
else
  pass_msg "DOCKER_PREFIX correctly omits MANUAL_MERGE token"
fi

# -------------------------------------------------------------------------
# Test 3 (ordering): in positive case, -e MANUAL_MERGE=1 appears BEFORE
# the service token 'claude-web-eval'. Otherwise docker-compose would
# treat MANUAL_MERGE=1 as a positional arg to the service.
# -------------------------------------------------------------------------
echo "Test 3: -e MANUAL_MERGE=1 appears before 'claude-web-eval' in DOCKER_PREFIX"
inc
if [ -z "$DOCKER_LINE" ]; then
  fail_msg "(ordering) no DOCKER_PREFIX= line available"
else
  # awk: emit index of substring within the line (0 if not found).
  IDX_ENV=$(awk -v s="-e MANUAL_MERGE=1" '{print index($0, s)}' <<<"$DOCKER_LINE")
  IDX_SVC=$(awk -v s="claude-web-eval" '{print index($0, s)}' <<<"$DOCKER_LINE")
  if [ "$IDX_ENV" = "0" ]; then
    fail_msg "(ordering) '-e MANUAL_MERGE=1' substring not found in DOCKER_PREFIX"
    echo "    $DOCKER_LINE"
  elif [ "$IDX_SVC" = "0" ]; then
    fail_msg "(ordering) 'claude-web-eval' substring not found in DOCKER_PREFIX"
    echo "    $DOCKER_LINE"
  elif [ "$IDX_ENV" -ge "$IDX_SVC" ]; then
    fail_msg "(ordering) -e MANUAL_MERGE=1 at col $IDX_ENV is NOT before claude-web-eval at col $IDX_SVC"
    echo "    $DOCKER_LINE"
  else
    pass_msg "(ordering) -e MANUAL_MERGE=1 (col $IDX_ENV) precedes claude-web-eval (col $IDX_SVC)"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
