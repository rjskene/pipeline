#!/bin/bash
set -uo pipefail

# Tests for spawn-claude.sh container-mode --env-file resolution + preflight
# env-threading (issue #257 Bug 1, Fix 2). Mirrors the harness pattern from
# tests/test-spawn-claude-container-mode.sh.
#
# Behaviors under test:
#   (a) A relative ENV_FILE configured via PIPELINE_EVAL_CONTAINER_*_ENV_FILE
#       must be resolved to absolute against WORKTREE_PATH BEFORE DOCKER_PREFIX
#       is assembled, so the resolved path matches where the probe wrote the
#       file (probe writes under PIPELINE_WORKTREE_PATH). See #269 — supersedes
#       the REPO_ROOT-rooted choice from #257.
#   (b) An already-absolute ENV_FILE must be passed through unchanged
#       (no double-prefix like <wt>/tmp/abs.env).
#   (c) The PREFLIGHT subprocess must inherit PIPELINE_PROJECT_ROOT and
#       PIPELINE_WORKTREE_PATH so probe scripts can resolve the per-worktree
#       env-file path.

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

# -------------------------------------------------------------------------
# Test (a): relative ENV_FILE -> resolved to <PROJ>/.env.web-eval (absolute)
# -------------------------------------------------------------------------
echo "Test (a): relative ENV_FILE resolved to absolute against WORKTREE_PATH"
inc
OUT_A=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=web-eval \
    "$PROJ/worktree" 201 slug tmux 2>&1 || true)
DOCKER_LINE_A=$(echo "$OUT_A" | grep -E '^DOCKER_PREFIX=' || true)
if [ -z "$DOCKER_LINE_A" ]; then
  fail_msg "Test (a): no DOCKER_PREFIX= line in dry-run output"
  echo "$OUT_A" | tail -10 | sed 's/^/    /'
elif ! echo "$DOCKER_LINE_A" | grep -q -- "--env-file $PROJ/worktree/.env.web-eval"; then
  fail_msg "Test (a): DOCKER_PREFIX missing absolute '--env-file $PROJ/worktree/.env.web-eval'"
  echo "  Got: $DOCKER_LINE_A"
else
  pass_msg "Test (a): DOCKER_PREFIX contains --env-file $PROJ/worktree/.env.web-eval"
fi

# -------------------------------------------------------------------------
# Test (b): absolute ENV_FILE passed through unchanged (no double-prefix)
# Uses a separate PROJ tree whose pipeline.config declares an absolute
# ENV_FILE so the sourced config sets the value to /tmp/abs.env.
# -------------------------------------------------------------------------
echo "Test (b): absolute ENV_FILE preserved verbatim"
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
PIPELINE_EVAL_CONTAINERS="web-eval"
PIPELINE_EVAL_CONTAINER_web_eval_COMPOSE_FILE="compose.web-eval.yml"
PIPELINE_EVAL_CONTAINER_web_eval_ENV_FILE="/tmp/abs.env"
PIPELINE_EVAL_CONTAINER_web_eval_SERVICE="claude-web-eval"
EOF
OUT_B=$(cd "$PROJ_B" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=web-eval \
    "$PROJ_B/worktree" 202 slug tmux 2>&1 || true)
DOCKER_LINE_B=$(echo "$OUT_B" | grep -E '^DOCKER_PREFIX=' || true)
if [ -z "$DOCKER_LINE_B" ]; then
  fail_msg "Test (b): no DOCKER_PREFIX= line in dry-run output"
elif ! echo "$DOCKER_LINE_B" | grep -q -- "--env-file /tmp/abs.env"; then
  fail_msg "Test (b): DOCKER_PREFIX missing '--env-file /tmp/abs.env'"
  echo "  Got: $DOCKER_LINE_B"
elif echo "$DOCKER_LINE_B" | grep -q -- "--env-file $PROJ_B/tmp/abs.env"; then
  fail_msg "Test (b): DOCKER_PREFIX has double-prefix $PROJ_B/tmp/abs.env"
  echo "  Got: $DOCKER_LINE_B"
else
  pass_msg "Test (b): DOCKER_PREFIX preserves absolute --env-file /tmp/abs.env"
fi

# -------------------------------------------------------------------------
# Test (c): PREFLIGHT subprocess inherits PIPELINE_PROJECT_ROOT + PIPELINE_WORKTREE_PATH
# -------------------------------------------------------------------------
echo "Test (c): PREFLIGHT inherits PIPELINE_PROJECT_ROOT and PIPELINE_WORKTREE_PATH"
inc
PROBE_OUT="$WORKDIR/probe-out.env"
rm -f "$PROBE_OUT"
# Preflight snippet: capture both env vars to a known file. Use printf so
# we don't rely on heredocs or quoting.
PRE_SNIPPET="printf 'PIPELINE_PROJECT_ROOT=%s\nPIPELINE_WORKTREE_PATH=%s\n' \"\$PIPELINE_PROJECT_ROOT\" \"\$PIPELINE_WORKTREE_PATH\" > $PROBE_OUT"
OUT_C=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  PIPELINE_EVAL_CONTAINER_web_eval_PREFLIGHT_CMD="$PRE_SNIPPET" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=web-eval \
    "$PROJ/worktree" 203 slug tmux 2>&1 || true)
if [ ! -f "$PROBE_OUT" ]; then
  fail_msg "Test (c): preflight did not write probe output file at $PROBE_OUT"
  echo "$OUT_C" | tail -15 | sed 's/^/    /'
else
  got_proj=$(grep '^PIPELINE_PROJECT_ROOT=' "$PROBE_OUT" | head -1 | sed 's/^PIPELINE_PROJECT_ROOT=//')
  got_wt=$(grep '^PIPELINE_WORKTREE_PATH=' "$PROBE_OUT" | head -1 | sed 's/^PIPELINE_WORKTREE_PATH=//')
  if [ -z "$got_proj" ]; then
    fail_msg "Test (c): PIPELINE_PROJECT_ROOT empty in preflight"
  elif [ -z "$got_wt" ]; then
    fail_msg "Test (c): PIPELINE_WORKTREE_PATH empty in preflight"
  elif [ "$got_proj" != "$PROJ" ]; then
    fail_msg "Test (c): PIPELINE_PROJECT_ROOT='$got_proj' != '$PROJ'"
  elif [ "$got_wt" != "$PROJ/worktree" ]; then
    fail_msg "Test (c): PIPELINE_WORKTREE_PATH='$got_wt' != '$PROJ/worktree'"
  else
    pass_msg "Test (c): PREFLIGHT saw PIPELINE_PROJECT_ROOT=$PROJ and PIPELINE_WORKTREE_PATH=$PROJ/worktree"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
