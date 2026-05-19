#!/bin/bash
set -uo pipefail

# Tests that scripts/run-queue.sh gates observability log writes on
# PIPELINE_LOGS_ENABLED. Uses PIPELINE_QUEUE_DRY_RUN=1 to short-circuit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/run-queue.sh"
LOGGING_HELPER="$REPO_ROOT/scripts/_logging.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs" "$proj/mock-web-eval/scripts"
  cp "$SCRIPT_UNDER_TEST" "$proj/.claude/scripts/run-queue.sh"
  cp "$LOGGING_HELPER" "$proj/.claude/scripts/_logging.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh"
  cp "$REPO_ROOT/mock-web-eval/scripts/eval-classifier-invoke.sh" "$proj/mock-web-eval/scripts/eval-classifier-invoke.sh"
  chmod +x "$proj/mock-web-eval/scripts/eval-classifier-invoke.sh"
  cat > "$proj/.claude/scripts/spawn-claude.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$proj/.claude/scripts/spawn-claude.sh"
  cat > "$proj/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=""
PIPELINE_EVAL_CONTAINERS=""
EOF
}

make_stubs() {
  local proj="$1"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$stub_dir/tmux"
  cat > "$stub_dir/gh" <<'EOF'
#!/bin/bash
echo ""
EOF
  chmod +x "$stub_dir/gh"
  cat > "$stub_dir/git" <<'EOF'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"
    slug="${entry##*:}"
    echo "worktree /tmp/wt-${issue}-${slug}"
    echo "HEAD abc123"
    echo "branch refs/heads/feature/${slug}"
    echo ""
  done
fi
EOF
  chmod +x "$stub_dir/git"
  echo "$stub_dir"
}

run_q() {
  local proj="$1"; shift
  local stub_dir="$1"; shift
  local logs_flag="$1"; shift
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"; slug="${entry##*:}"
    mkdir -p "/tmp/wt-${issue}-${slug}"
  done
  (
    cd "$proj"
    PATH="$stub_dir:$PATH" \
      TMUX="fake" \
      STUB_WORKTREES="${STUB_WORKTREES:-}" \
      PIPELINE_QUEUE_DRY_RUN=1 \
      PIPELINE_LOGS_ENABLED="$logs_flag" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      bash .claude/scripts/run-queue.sh "$@" 2>&1
  )
}

# ---- Test 1: PIPELINE_LOGS_ENABLED unset -> no log files, stdout preserved ----
echo "Test 1: logs disabled -> no queue-*.log / queue-pending.txt, stdout still has progress"
inc
PROJ="$WORKDIR/p1"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
OUT=$(STUB_WORKTREES="200:foo 201:bar" run_q "$PROJ" "$STUB_DIR" "false" 200 201)
ok=1
if ls "$PROJ/.claude/logs/"queue-*.log >/dev/null 2>&1; then
  fail_msg "queue-*.log files should NOT exist when PIPELINE_LOGS_ENABLED=false"
  ls "$PROJ/.claude/logs/" | sed 's/^/    /'
  ok=0
fi
if [ -f "$PROJ/.claude/logs/queue-pending.txt" ]; then
  fail_msg "queue-pending.txt should NOT exist when PIPELINE_LOGS_ENABLED=false"
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT" | grep -q 'AGENT QUEUE RUNNER'; then
  fail_msg "stdout missing 'AGENT QUEUE RUNNER' progress line (log() must still echo)"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT" | grep -qE 'BUCKET: mode=bare'; then
  fail_msg "stdout missing BUCKET line — script may have aborted"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "no log files; stdout progress preserved"

# ---- Test 2: PIPELINE_LOGS_ENABLED=true -> log files created ----
echo "Test 2: logs enabled -> queue-*.log and queue-pending.txt both appear"
inc
PROJ="$WORKDIR/p2"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
OUT=$(STUB_WORKTREES="200:foo 201:bar" run_q "$PROJ" "$STUB_DIR" "true" 200 201)
ok=1
if ! ls "$PROJ/.claude/logs/"queue-*.log >/dev/null 2>&1; then
  fail_msg "queue-*.log should exist when PIPELINE_LOGS_ENABLED=true"
  ls "$PROJ/.claude/logs/" 2>&1 | sed 's/^/    /'
  ok=0
fi
if [ ! -f "$PROJ/.claude/logs/queue-pending.txt" ]; then
  fail_msg "queue-pending.txt should exist when PIPELINE_LOGS_ENABLED=true"
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "both log files created"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
