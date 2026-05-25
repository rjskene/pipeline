#!/bin/bash
set -uo pipefail

# Regression guard for issue #490: scripts/run-queue.sh must propagate
# PIPELINE_PROJECT_ROOT to the periodic queue-status.sh poll helper.
#
# The bug: the status-invocation site called `bash queue-status.sh ...` WITHOUT
# the `PIPELINE_PROJECT_ROOT="$REPO_ROOT"` prefix that every other child-bash
# invocation in run-queue.sh carries (cf. the classifier call ~line 207). With
# the env var unset, queue-status.sh's _find_main_repo fell back to walking up
# from its own `dirname $0` — which under a plugin-cache install is NOT inside
# the consumer checkout — and emitted the recurring
# `ERROR: could not locate consumer repo` line on every poll.
#
# Strategy (mirrors tests/test-run-queue-stall-detection.sh's proven harness):
# drive the REAL poll loop with two issues that both finish on the first poll
# (tmux list-windows returns empty, so is_agent_running is false immediately).
# STATUS_INTERVAL=1 makes the periodic status branch fire on that first poll.
# queue-status.sh is replaced with a stub that records the PIPELINE_PROJECT_ROOT
# it inherited. We assert the stub saw the consumer-repo root (REPO_ROOT, which
# defaults to the runner's pwd) and NOT `UNSET`.
#
# RED (pre-fix): the invocation lacks the env prefix, the stub records
#   PIPELINE_PROJECT_ROOT=UNSET, and the project-root assertion fails.
# GREEN (post-fix): the inline `PIPELINE_PROJECT_ROOT="$REPO_ROOT"` prefix makes
#   the stub record the project dir.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/run-queue.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Build a fake consumer project tree (matches the stall-detection harness shape):
# a .claude/scripts/ dir holding the script under test + its sibling helpers, a
# pipeline.config, and a .git/ marker so any walk-up resolution has a real anchor.
setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs" "$proj/.git"
  cp "$SCRIPT_UNDER_TEST" "$proj/.claude/scripts/run-queue.sh"
  cp "$REPO_ROOT/scripts/_logging.sh" "$proj/.claude/scripts/_logging.sh"
  cp "$REPO_ROOT/scripts/_resolve-container-var.sh" "$proj/.claude/scripts/_resolve-container-var.sh"
  cp "$REPO_ROOT/scripts/eval-classifier-invoke.sh" "$proj/.claude/scripts/eval-classifier-invoke.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh" "$proj/.claude/scripts/eval-classifier-invoke.sh"

  # Stub queue-status.sh: record the PIPELINE_PROJECT_ROOT this child inherited.
  # Writes a stable marker line both to stdout (which the runner tees) and to a
  # sentinel file resolved from the stub's own location (== $proj), so the
  # assertion does not depend on the runner's stdout-tee path being exercised.
  cat > "$proj/.claude/scripts/queue-status.sh" <<'EOF'
#!/bin/bash
_self_dir="$(cd "$(dirname "$0")" && pwd)"
_proj="$(cd "$_self_dir/../.." && pwd)"
echo "PIPELINE_PROJECT_ROOT=${PIPELINE_PROJECT_ROOT:-UNSET}" | tee "$_proj/status-marker.txt"
exit 0
EOF
  chmod +x "$proj/.claude/scripts/queue-status.sh"

  # spawn-claude.sh stub: launching an agent is a no-op success.
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

# Minimal stub set: agents finish on the first poll (list-windows empty), gh/git
# return innocuous output, ps reports nothing.
make_stubs() {
  local proj="$1"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"

  cat > "$stub_dir/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  list-windows) ;;            # empty -> is_agent_running() false on poll 1
  list-panes)   echo "90000" ;;
  *)            exit 0 ;;
esac
EOF
  chmod +x "$stub_dir/tmux"

  cat > "$stub_dir/ps" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$stub_dir/ps"

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

# ---- Test 1: queue-status.sh inherits PIPELINE_PROJECT_ROOT=<consumer root> ----
echo "Test 1: run-queue.sh propagates PIPELINE_PROJECT_ROOT to the queue-status poll"
inc
PROJ="$WORKDIR/p1"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
for entry in 701:foo 702:bar; do
  issue="${entry%%:*}"; slug="${entry##*:}"
  mkdir -p "/tmp/wt-${issue}-${slug}"
done

STDOUT_CAPTURE="$WORKDIR/queue-stdout.log"
# NOTE: PIPELINE_PROJECT_ROOT is intentionally NOT set in this environment, so
# REPO_ROOT falls back to the runner's pwd ($PROJ). If the runner fails to
# forward it, the child stub sees UNSET — the RED condition.
(
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    TMUX="fake" \
    STUB_WORKTREES="701:foo 702:bar" \
    PIPELINE_LOGS_ENABLED=true \
    POLL_SECONDS=1 \
    STATUS_INTERVAL=1 \
    CLAUDE_PLUGIN_ROOT="$PROJ/.claude" \
    bash .claude/scripts/run-queue.sh 701 702
) > "$STDOUT_CAPTURE" 2>&1

MARKER_FILE="$PROJ/status-marker.txt"
ok=1

if [ ! -f "$MARKER_FILE" ]; then
  fail_msg "queue-status stub never ran (no status-marker.txt) — status branch not reached"
  echo "--- stdout capture ---" >&2
  sed 's/^/    /' "$STDOUT_CAPTURE" >&2
  ok=0
fi

if [ "$ok" = "1" ]; then
  marker=$(cat "$MARKER_FILE")
  if [ "$marker" = "PIPELINE_PROJECT_ROOT=$PROJ" ]; then
    pass_msg "queue-status inherited PIPELINE_PROJECT_ROOT=$PROJ"
  else
    fail_msg "expected 'PIPELINE_PROJECT_ROOT=$PROJ', got '$marker'"
    ok=0
  fi
fi

# Belt-and-suspenders: the marker must never be the UNSET sentinel.
if [ "$ok" = "1" ] && grep -q 'PIPELINE_PROJECT_ROOT=UNSET' "$MARKER_FILE"; then
  fail_msg "queue-status saw PIPELINE_PROJECT_ROOT=UNSET — env not propagated"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
