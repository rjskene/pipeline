#!/bin/bash
set -uo pipefail

# Regression for issue #685: a SINGLE-issue queue must block until its one
# worker reaches terminal state and emit `EVENT: queue-complete total=1`
# exactly once — NOT exit 0 in seconds while the worker is still live.
#
# Before the fix, scripts/run-queue.sh had a single-issue short-circuit that
# spawned the worker into a detached tmux window then `exit 0` without ever
# entering the poll loop or emitting queue-complete. This test drives the FULL
# (non-dry-run) runner with a one-issue queue and asserts the worker is
# observed live for >=1 poll (agent-launched precedes agent-finished) and that
# queue-complete fires exactly once.
#
# Strategy mirrors test-run-queue-executor-terminal.sh: issue 911's tmux window
# is PRESENT on the first poll then disappears (window absent => is_agent_running
# false), so the existing is_agent_running==false reap branch frees the slot,
# the poll loop's `${#ACTIVE[@]} -gt 0` condition goes false, and the runner
# falls through to the queue-complete emission.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/run-queue.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT=$(mktemp -d)
mkdir -p "/tmp/wt-911-solo"
trap 'rm -rf "$ROOT" "/tmp/wt-911-solo"' EXIT

setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs"
  cp "$SCRIPT_UNDER_TEST" "$proj/.claude/scripts/run-queue.sh"
  cp "$REPO_ROOT/scripts/_logging.sh" "$proj/.claude/scripts/_logging.sh"
  cp "$REPO_ROOT/scripts/queue-status.sh" "$proj/.claude/scripts/queue-status.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh" "$proj/.claude/scripts/queue-status.sh"
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
EOF
}

# tmux/ps/git/gh stubs. 911's window is present on poll 1 then disappears once
# the marker is written by the first list-windows call, so the worker is
# observed live for one poll then reaped via is_agent_running==false.
make_stubs() {
  local proj="$1"
  local case_dir="$2"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"
  local seen_marker="$case_dir/seen-911"

  cat > "$stub_dir/tmux" <<EOF
#!/bin/bash
SEEN_MARKER="$seen_marker"
case "\$1" in
  list-windows)
    # 911 present on the first poll, absent thereafter (single drain step).
    if [ ! -f "\$SEEN_MARKER" ]; then
      : > "\$SEEN_MARKER"
      echo "issue-911"
    fi
    ;;
  list-panes)
    echo "99911"
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$stub_dir/tmux"

  cat > "$stub_dir/ps" <<'EOF'
#!/bin/bash
mode=""
for arg in "$@"; do
  case "$arg" in
    -eo)   mode="eo" ;;
    pgid=) mode="pgid" ;;
  esac
done
if [ "$mode" = "pgid" ]; then
  echo ""
elif [ "$mode" = "eo" ]; then
  echo "99911 1 50.0"
else
  echo "0.0"
fi
EOF
  chmod +x "$stub_dir/ps"

  cat > "$stub_dir/git" <<'EOF'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  echo "worktree /tmp/wt-911-solo"
  echo "HEAD abc123"
  echo "branch refs/heads/feature/solo"
  echo ""
fi
EOF
  chmod +x "$stub_dir/git"

  # gh stub: 911 carries pr-open so check_issue_outcome records a real outcome;
  # pr list / pr view empty so no evaluator path interferes.
  cat > "$stub_dir/gh" <<'EOF'
#!/bin/bash
ARGS="$*"
case "$1 $2" in
  "issue view")
    if [[ "$ARGS" == *labels* ]]; then echo "pr-open"; fi
    ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
  chmod +x "$stub_dir/gh"

  echo "$stub_dir"
}

run_case() {
  local proj="$1"
  local case_dir="$2"
  local tmo="$3"
  (
    cd "$proj"
    PATH="$proj/stub:$PATH" \
      TMUX="fake" \
      POLL_SECONDS=1 \
      STATUS_INTERVAL=999 \
      PIPELINE_PROJECT_ROOT="$proj" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      timeout "$tmo" bash .claude/scripts/run-queue.sh 911
  ) > "$case_dir/queue.log" 2>&1 || true
}

# ===================== Case A: single-issue queue blocks then completes =====================
echo "Case A: a single-issue queue blocks until its worker terminates, then emits queue-complete"
CASE_A="$ROOT/caseA"; mkdir -p "$CASE_A"
PROJ_A="$CASE_A/proj"
setup_proj "$PROJ_A"
make_stubs "$PROJ_A" "$CASE_A" >/dev/null
run_case "$PROJ_A" "$CASE_A" 30

inc
# The worker must be observed live (launched) before it is reaped (finished) —
# i.e. the runner entered the poll loop rather than short-circuiting to exit 0.
if grep -q 'EVENT: agent-launched issue=911' "$CASE_A/queue.log" \
   && grep -q 'EVENT: agent-finished issue=911' "$CASE_A/queue.log"; then
  pass_msg "A1: runner entered the poll loop (agent-launched then agent-finished for 911)"
else
  fail_msg "A1: expected agent-launched then agent-finished for 911 (runner did not block in the poll loop)"
  sed 's/^/    /' "$CASE_A/queue.log" >&2
fi

inc
QC_COUNT=$(grep -c 'EVENT: queue-complete total=1' "$CASE_A/queue.log")
if [ "$QC_COUNT" -eq 1 ]; then
  pass_msg "A2: queue-complete total=1 emitted exactly once for the single-issue queue"
else
  fail_msg "A2: expected exactly one 'EVENT: queue-complete total=1' (got $QC_COUNT)"
  sed 's/^/    /' "$CASE_A/queue.log" >&2
fi

# ===================== Case B: queue-complete emitted exactly once (no zero, no dup) =====================
echo ""
echo "Case B: queue-complete is emitted exactly once (not zero, not duplicated)"
CASE_B="$ROOT/caseB"; mkdir -p "$CASE_B"
PROJ_B="$CASE_B/proj"
setup_proj "$PROJ_B"
make_stubs "$PROJ_B" "$CASE_B" >/dev/null
run_case "$PROJ_B" "$CASE_B" 30

inc
QC_ALL=$(grep -c 'EVENT: queue-complete' "$CASE_B/queue.log")
if [ "$QC_ALL" -eq 1 ]; then
  pass_msg "B1: exactly one queue-complete emission"
else
  fail_msg "B1: expected exactly one 'EVENT: queue-complete' (got $QC_ALL)"
  sed 's/^/    /' "$CASE_B/queue.log" >&2
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
