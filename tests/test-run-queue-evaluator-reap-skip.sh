#!/bin/bash
set -uo pipefail
# Regression guard for issue #694: scripts/run-queue.sh must NOT reap a worker
# whose issue is `pr-open` from launch (an evaluator's INPUT state) even when the
# queue carries NO --skill flag (default/mixed queue). The #666 queue-level
# QUEUE_SKILL guard only covers `--skill evaluate-issue-pr` queues; this asserts
# the transition-witness (SAW_OFF_PR_OPEN) protects the evaluator for ANY queue.
#
# Strategy mirrors test-run-queue-executor-terminal.sh: drive the full poll loop
# (non-dry-run) with a two-issue queue (911 + 912). 911 sits at `pr-open` on
# EVERY poll (never witnessed off pr-open => never a "finished executor"); 912
# finishes on poll 1. No --skill flag is passed, so only the transition witness
# (not the queue-skill guard) can prevent the reap.
#
# Expected on first run (RED, before SAW_OFF_PR_OPEN is wired): G1/G2 FAIL (911
# reaped after the grace window because the snapshot-only predicate fires).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/run-queue.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT=$(mktemp -d)
mkdir -p "/tmp/wt-911-exec" "/tmp/wt-912-bar"
trap 'rm -rf "$ROOT" "/tmp/wt-911-exec" "/tmp/wt-912-bar"' EXIT

setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs"
  cp "$SCRIPT_UNDER_TEST" "$proj/.claude/scripts/run-queue.sh"
  cp "$REPO_ROOT/scripts/_logging.sh" "$proj/.claude/scripts/_logging.sh"
  cp "$REPO_ROOT/scripts/queue-status.sh" "$proj/.claude/scripts/queue-status.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh" "$proj/.claude/scripts/queue-status.sh"
  cat > "$proj/.claude/scripts/spawn-claude.sh" <<'SC'
#!/bin/bash
exit 0
SC
  chmod +x "$proj/.claude/scripts/spawn-claude.sh"
  cat > "$proj/.bash_env" <<'BE'
enable -n kill 2>/dev/null || true
BE
  cat > "$proj/pipeline.config" <<CFG
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
CFG
}

make_common_stubs() {
  local proj="$1"; local case_dir="$2"
  local stub_dir="$proj/stub"; mkdir -p "$stub_dir"
  local killed_marker="$case_dir/killed-911"
  cat > "$stub_dir/tmux" <<TM
#!/bin/bash
KILLED_MARKER="$killed_marker"
case "\$1" in
  list-windows) [ -f "\$KILLED_MARKER" ] && exit 0; echo "issue-911" ;;
  list-panes)
    target=""; shift
    while [ \$# -gt 0 ]; do case "\$1" in -t) target="\$2"; shift 2 ;; *) shift ;; esac; done
    case "\$target" in *issue-911) echo "99911" ;; *issue-912) echo "99912" ;; *) echo "99000" ;; esac ;;
  kill-window)
    target=""; shift
    while [ \$# -gt 0 ]; do case "\$1" in -t) target="\$2"; shift 2 ;; *) shift ;; esac; done
    case "\$target" in *issue-911) : > "\$KILLED_MARKER" ;; esac ;;
  *) exit 0 ;;
esac
TM
  chmod +x "$stub_dir/tmux"
  cat > "$stub_dir/ps" <<'PS'
#!/bin/bash
mode=""; pid=""; want_pid=0
for arg in "$@"; do
  case "$arg" in
    -eo) mode="eo" ;;
    pgid=) mode="pgid" ;;
    -p) want_pid=1 ;;
    *) if [ "$want_pid" = 1 ]; then pid="$arg"; want_pid=0; fi ;;
  esac
done
if [ "$mode" = "pgid" ]; then
  if [ "$pid" = "99911" ]; then echo "88811"; else echo ""; fi
elif [ "$mode" = "eo" ]; then echo "99911 1 50.0"; else echo "0.0"; fi
PS
  chmod +x "$stub_dir/ps"
  cat > "$stub_dir/kill" <<KL
#!/bin/bash
echo "\$*" >> "$case_dir/kill-log"
exit 0
KL
  chmod +x "$stub_dir/kill"
  cat > "$stub_dir/git" <<'GT'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"; slug="${entry##*:}"
    echo "worktree /tmp/wt-${issue}-${slug}"; echo "HEAD abc123"
    echo "branch refs/heads/feature/${slug}"; echo ""
  done
fi
GT
  chmod +x "$stub_dir/git"
  echo "$stub_dir"
}

run_case() {
  local proj="$1"; local case_dir="$2"; local tmo="$3"; local grace_polls="$4"; local extra_args="${5:-}"
  ( cd "$proj"
    PATH="$proj/stub:$PATH" TMUX="fake" STUB_WORKTREES="911:exec 912:bar" \
      POLL_SECONDS=1 STATUS_INTERVAL=999 \
      PIPELINE_EXECUTOR_REAP_GRACE_POLLS="$grace_polls" \
      PIPELINE_REAP_SIGKILL_GRACE_SEC=0 BASH_ENV="$proj/.bash_env" \
      PIPELINE_PROJECT_ROOT="$proj" CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      timeout "$tmo" bash .claude/scripts/run-queue.sh $extra_args 911 912
  ) > "$case_dir/queue.log" 2>&1 || true
}

echo "Case G: DEFAULT-skill queue does NOT reap a worker pr-open from launch (transition witness, #694)"
CASE_G="$ROOT/caseG"; mkdir -p "$CASE_G"
PROJ_G="$CASE_G/proj"
setup_proj "$PROJ_G"
STUB_G=$(make_common_stubs "$PROJ_G" "$CASE_G")
cat > "$STUB_G/gh" <<'GH'
#!/bin/bash
ARGS="$*"
case "$1 $2" in
  "issue view")
    issue="$3"
    if [[ "$ARGS" == *labels* ]]; then
      if [ "$issue" = "911" ]; then echo "pr-open"; else echo ""; fi
    fi ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
GH
chmod +x "$STUB_G/gh"
# NO --skill flag (default queue), grace=2, generous 30s timeout: absent the
# transition gate the executor reap WOULD fire => real RED.
run_case "$PROJ_G" "$CASE_G" 30 2 ""

inc
if ! grep -q 'EVENT: agent-finished issue=911 outcome=pr-open' "$CASE_G/queue.log"; then
  pass_msg "G1: default-skill queue does NOT reap a worker pr-open since launch"
else
  fail_msg "G1: executor reap fired for a worker pr-open from t=0 in a default-skill queue"
  sed 's/^/    /' "$CASE_G/queue.log" >&2
fi
inc
if [ ! -f "$CASE_G/killed-911" ]; then
  pass_msg "G2: default-skill queue did NOT force-close a never-transitioned worker's window"
else
  fail_msg "G2: runner force-closed a worker that was pr-open since launch"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
