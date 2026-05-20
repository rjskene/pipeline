#!/bin/bash
set -uo pipefail

# Tests for the --container-mode dispatch added to spawn-claude.sh
# (issue #218). Runs spawn-claude.sh with PIPELINE_SPAWN_DRY_RUN=1 in a temp
# project tree, with `gh` stubbed so no network is required. Follows the
# pattern of test-spawn-claude-runs-log.sh.

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

# Minimal pipeline.config — enough for the spawn template to source without
# tripping `set -u`.
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

# Stub gh: returns labels from STUB_LABELS.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$STUB_DIR/gh"

# Stub docker: a sentinel binary; spawn-claude shouldn't *invoke* docker in
# dry-run mode (only emit it into BUILD_ARGV), but we provide one so any
# accidental `command -v docker` returns truthy.
cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
echo "STUB_DOCKER $*"
EOF
chmod +x "$STUB_DIR/docker"

RUNS_LOG="$WORKDIR/runs.log"

run_dryrun() {
  # Args: <issue> <skill> [extra spawn-claude args...]
  local issue="$1" skill="$2"; shift 2
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    PIPELINE_LOGS_ENABLED=true \
    PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
    bash .claude/scripts/spawn-claude.sh \
      --skill "$skill" "$@" "$PROJ/worktree" "$issue" slug tmux \
      2>"$WORKDIR/last.err"
  local rc=$?
  cd - >/dev/null
  echo "EXIT=$rc"
  return "$rc"
}

# -------------------------------------------------------------------------
# Test 1: bare host (no --container-mode) — BUILD_ARGV contains `claude` literal
# -------------------------------------------------------------------------
echo "Test 1: no --container-mode -> bare-host BUILD_ARGV"
inc
OUT="$(run_dryrun 100 evaluate-issue-pr)" || true
BUILD_BLOCK=$(echo "$OUT" | sed -n '/^=== BUILD_ARGV ===$/,/^=== END BUILD_ARGV ===$/p')
if echo "$BUILD_BLOCK" | grep -qE '\bdocker compose\b'; then
  fail_msg "bare-host BUILD_ARGV unexpectedly contains 'docker compose'"
elif ! echo "$BUILD_BLOCK" | grep -qE '^CLAUDE_ARGV\+|printf .* claude|exec script'; then
  # spawn-claude doesn't print the launcher in dry-run, but the BUILD_ARGV
  # block is the snippet template; just confirm CLAUDE_ARGV is set up here.
  if echo "$BUILD_BLOCK" | grep -q 'CLAUDE_ARGV'; then
    pass_msg "BUILD_ARGV is bare-host (CLAUDE_ARGV configured, no docker)"
  else
    fail_msg "BUILD_ARGV block does not configure CLAUDE_ARGV"
    echo "$BUILD_BLOCK" | sed 's/^/    /'
  fi
else
  pass_msg "BUILD_ARGV is bare-host (no docker compose)"
fi

# -------------------------------------------------------------------------
# Test 2: --container-mode=web-eval -> docker compose prefix in BUILD_ARGV
# -------------------------------------------------------------------------
echo "Test 2: --container-mode=web-eval emits docker compose prefix"
inc
OUT="$(run_dryrun 101 evaluate-issue-pr --container-mode=web-eval)" || true
BUILD_BLOCK=$(echo "$OUT" | sed -n '/^=== BUILD_ARGV ===$/,/^=== END BUILD_ARGV ===$/p')
DOCKER_LINE=$(echo "$OUT" | grep -E '^DOCKER_PREFIX=' || true)
if [ -z "$DOCKER_LINE" ]; then
  fail_msg "no DOCKER_PREFIX= line in dry-run output"
  echo "$OUT" | sed 's/^/    /'
else
  ok=1
  echo "$DOCKER_LINE" | grep -q "docker compose"               || { fail_msg "DOCKER_PREFIX missing 'docker compose'"; ok=0; }
  [ "$ok" = "1" ] && (echo "$DOCKER_LINE" | grep -qE -- "--env-file ($PROJ/)?\\.env\\.web-eval"  || { fail_msg "DOCKER_PREFIX missing --env-file [\$PROJ/].env.web-eval"; ok=0; })
  [ "$ok" = "1" ] && (echo "$DOCKER_LINE" | grep -q -- "-f compose.web-eval.yml"   || { fail_msg "DOCKER_PREFIX missing '-f compose.web-eval.yml'"; ok=0; })
  [ "$ok" = "1" ] && (echo "$DOCKER_LINE" | grep -q "run --rm"                     || { fail_msg "DOCKER_PREFIX missing 'run --rm'"; ok=0; })
  [ "$ok" = "1" ] && (echo "$DOCKER_LINE" | grep -q "CLAUDE_PIPELINE_ISSUE_NUMBER=101" || { fail_msg "DOCKER_PREFIX missing -e CLAUDE_PIPELINE_ISSUE_NUMBER=101"; ok=0; })
  [ "$ok" = "1" ] && (echo "$DOCKER_LINE" | grep -q "CLAUDE_PIPELINE_SKILL=evaluate-issue-pr" || { fail_msg "DOCKER_PREFIX missing -e CLAUDE_PIPELINE_SKILL"; ok=0; })
  [ "$ok" = "1" ] && (echo "$DOCKER_LINE" | grep -q "claude-web-eval"              || { fail_msg "DOCKER_PREFIX missing service 'claude-web-eval'"; ok=0; })
  [ "$ok" = "1" ] && pass_msg "DOCKER_PREFIX has docker compose + env-file + compose-file + run --rm + env vars + service"
fi

# -------------------------------------------------------------------------
# Test 3: preflight exits 0 -> 'PREFLIGHT: pass' line in stderr/dry-run
# -------------------------------------------------------------------------
echo "Test 3: preflight rc=0 emits 'PREFLIGHT: pass'"
inc
PREFLIGHT_OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  PIPELINE_EVAL_CONTAINER_web_eval_PREFLIGHT_CMD="bash -c 'exit 0'" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=web-eval \
    "$PROJ/worktree" 102 slug tmux 2>&1 || true)
if echo "$PREFLIGHT_OUT" | grep -q "PREFLIGHT: pass"; then
  pass_msg "preflight rc=0 emitted 'PREFLIGHT: pass'"
else
  fail_msg "no 'PREFLIGHT: pass' line in output"
  echo "$PREFLIGHT_OUT" | tail -20 | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 4: preflight rc!=0 -> non-zero exit + error stderr
# -------------------------------------------------------------------------
echo "Test 4: preflight rc=7 fails spawn-claude with rc-bearing stderr"
inc
PREFLIGHT_FAIL_OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  PIPELINE_EVAL_CONTAINER_web_eval_PREFLIGHT_CMD="bash -c 'exit 7'" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=web-eval \
    "$PROJ/worktree" 103 slug tmux 2>&1 ; echo "RC=$?") || true
PREFLIGHT_RC=$(echo "$PREFLIGHT_FAIL_OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$PREFLIGHT_RC" = "0" ]; then
  fail_msg "preflight failure should produce non-zero spawn exit, got 0"
elif ! echo "$PREFLIGHT_FAIL_OUT" | grep -q "container-mode preflight failed (rc=7)"; then
  fail_msg "missing expected stderr 'container-mode preflight failed (rc=7)'"
  echo "$PREFLIGHT_FAIL_OUT" | tail -15 | sed 's/^/    /'
else
  pass_msg "non-zero exit ($PREFLIGHT_RC) + correct stderr"
fi

# -------------------------------------------------------------------------
# Test 5: mode not declared in PIPELINE_EVAL_CONTAINERS -> exit non-zero
# -------------------------------------------------------------------------
echo "Test 5: undeclared --container-mode rejected"
inc
UNDECLARED_OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=ghost-mode \
    "$PROJ/worktree" 104 slug tmux 2>&1 ; echo "RC=$?") || true
UNDECLARED_RC=$(echo "$UNDECLARED_OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$UNDECLARED_RC" = "0" ]; then
  fail_msg "undeclared mode should fail; got rc=0"
elif ! echo "$UNDECLARED_OUT" | grep -q "container-mode 'ghost-mode' not declared in PIPELINE_EVAL_CONTAINERS"; then
  fail_msg "missing expected stderr 'container-mode .ghost-mode. not declared in PIPELINE_EVAL_CONTAINERS'"
  echo "$UNDECLARED_OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "undeclared mode rejected (rc=$UNDECLARED_RC) with explicit error"
fi

# -------------------------------------------------------------------------
# Test 6: --classifier-passthrough=<tok> forwarded as EXTRA CLAUDE_ARGV entry
# -------------------------------------------------------------------------
echo "Test 6: --classifier-passthrough forwarded into CLAUDE_ARGV"
inc
PASSTHRU_OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr \
    --container-mode=web-eval \
    --classifier-passthrough=--foo=bar \
    "$PROJ/worktree" 105 slug tmux 2>&1 || true)
BUILD_BLOCK=$(echo "$PASSTHRU_OUT" | sed -n '/^=== BUILD_ARGV ===$/,/^=== END BUILD_ARGV ===$/p')
if echo "$BUILD_BLOCK" | grep -qE 'CLAUDE_ARGV\+=\(--foo=bar\)'; then
  pass_msg "BUILD_ARGV adds CLAUDE_ARGV+=(--foo=bar)"
else
  fail_msg "BUILD_ARGV missing CLAUDE_ARGV+=(--foo=bar) for passthrough"
  echo "$BUILD_BLOCK" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 7: --container-mode with a skill NOT in PIPELINE_CONTAINER_SKILLS
# allowlist -> rejected. The default allowlist (when the env var is unset)
# is "evaluate-issue-pr", so --skill=execute-issue-plan should still fail —
# but the stderr wording is now the allowlist-based form introduced by #321,
# not the legacy "only supported with --skill=evaluate-issue-pr" string.
# -------------------------------------------------------------------------
echo "Test 7: --container-mode rejected for skills outside PIPELINE_CONTAINER_SKILLS"
inc
GATE_OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill execute-issue-plan --container-mode=web-eval \
    "$PROJ/worktree" 106 slug tmux 2>&1 ; echo "RC=$?") || true
GATE_RC=$(echo "$GATE_OUT" | grep -E '^RC=' | tail -1 | sed 's/RC=//')
if [ "$GATE_RC" = "0" ]; then
  fail_msg "expected non-zero exit when --container-mode used with execute-issue-plan; got 0"
elif ! echo "$GATE_OUT" | grep -q "container-mode rejected: skill 'execute-issue-plan' not in PIPELINE_CONTAINER_SKILLS allowlist"; then
  fail_msg "missing expected stderr 'container-mode rejected: skill execute-issue-plan not in PIPELINE_CONTAINER_SKILLS allowlist'"
  echo "$GATE_OUT" | tail -10 | sed 's/^/    /'
else
  pass_msg "non-zero exit ($GATE_RC) + correct allowlist-error stderr"
fi

# -------------------------------------------------------------------------
# Test 8: --container-mode injects -e PIPELINE_PROJECT_ROOT=<proj> and
#         -e PIPELINE_WORKTREE_PATH=<worktree> into DOCKER_PREFIX, so the
#         compose file's same-path project-root bind + working_dir math
#         resolves correctly. Fixes #241 (plugin slash commands
#         not discoverable inside container).
# -------------------------------------------------------------------------
echo "Test 8: --container-mode injects PIPELINE_PROJECT_ROOT + PIPELINE_WORKTREE_PATH"
inc
PR_OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  STUB_LABELS="" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=true \
  PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
  bash .claude/scripts/spawn-claude.sh \
    --skill evaluate-issue-pr --container-mode=web-eval \
    "$PROJ/worktree" 107 slug tmux 2>&1 || true)
DOCKER_LINE=$(echo "$PR_OUT" | grep -E '^DOCKER_PREFIX=' || true)
if [ -z "$DOCKER_LINE" ]; then
  fail_msg "Test 8: no DOCKER_PREFIX= line"
else
  ok=1
  echo "$DOCKER_LINE" | grep -q "PIPELINE_PROJECT_ROOT=$PROJ"           || { fail_msg "Test 8: DOCKER_PREFIX missing -e PIPELINE_PROJECT_ROOT=$PROJ"; ok=0; }
  [ "$ok" = "1" ] && (echo "$DOCKER_LINE" | grep -q "PIPELINE_WORKTREE_PATH=$PROJ/worktree" || { fail_msg "Test 8: DOCKER_PREFIX missing -e PIPELINE_WORKTREE_PATH=$PROJ/worktree"; ok=0; })
  [ "$ok" = "1" ] && pass_msg "Test 8: DOCKER_PREFIX carries -e PIPELINE_PROJECT_ROOT and -e PIPELINE_WORKTREE_PATH"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
