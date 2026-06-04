#!/bin/bash
set -uo pipefail

# Tests scripts/run-queue.sh stored-PGID reap (issue #919): reap_worker_window
# must tear down the worker process GROUP via the pgid CAPTURED AT SPAWN TIME,
# unconditionally — even when the tmux pane lead pid has already died by reap
# time (OOM kill / crash), so an at-reap-time `ps -o pgid= -p <dead pid>` lookup
# returns empty.
#
# Strategy mirrors tests/test-run-queue-executor-terminal.sh Case F: drive the
# FULL poll loop (non-dry-run) with a wedged executor (911) that opened a PR +
# applied `pr-open`, then gets reaped by the executor-terminal grace path. The
# new twist: 911's pane lead pid is killed EXTERNALLY mid-run, so:
#   - At LAUNCH (lead alive): `tmux list-panes` echoes pane lead pid 99911 and
#     `ps -o pgid= -p 99911` echoes the captured group 88811. The runner stores
#     88811 in WORKER_PGID[911] at spawn time.
#   - At REAP (lead dead): a `dead-911` marker exists; `tmux list-panes` echoes
#     EMPTY and `ps -o pgid=` echoes EMPTY, so the LEGACY at-reap-time lookup
#     would resolve no pgid and SKIP the group-kill.
# The reap must use the STORED pgid (88811) and still SIGTERM+SIGKILL the group.
#
# Two sub-cases:
#   A (acceptance): dead-lead reap via stored pgid. The lead is killed before the
#       reap fires. Assert kill-log contains `-TERM -88811` AND `-KILL -88811`
#       (reap used the stored pgid) and that the `dead-911` marker exists before
#       the reap (the lead was truly gone). RED before impl: the current reap
#       re-derives the pgid at reap time, gets empty, and skips the group-kill →
#       no `-88811` lines in the kill-log.
#   B (regression guard): live-lead reap still works. The lead stays resolvable
#       the whole run (ps `-o pgid=` echoes 88811 throughout). Assert the kill-log
#       still contains `-TERM -88811` and `-KILL -88811`. Passes before and after
#       impl (guards the fallback path + the common case).
#
# Fully stubbed — no real process is signalled (all signals hit the stub pgid
# 88811, recorded in a kill-log), `kill`/`tmux`/`ps`/`git`/`gh` are stubs, and
# scratch dirs are mktemp -d cleaned via `trap … EXIT`. stdin is redirected from
# /dev/null in run_case so PIPELINE_TEST_CMD never hangs on an interactive read.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/run-queue.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT=$(mktemp -d)
WT_BASE="$ROOT/worktrees"
export STUB_WT_BASE="$WT_BASE"
mkdir -p "$WT_BASE/wt-911-exec"
trap 'rm -rf "$ROOT"' EXIT

# Build a project tree with run-queue.sh + its sourced deps and a minimal config.
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
  # `kill` is a bash BUILTIN; BASH_ENV disables it so the reap's process-group
  # signals resolve to the PATH `kill` stub and we can observe the signalled pgid.
  cat > "$proj/.bash_env" <<'EOF'
enable -n kill 2>/dev/null || true
EOF
  cat > "$proj/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
EOF
}

# tmux + ps + git + kill stubs shared by both cases. $1=proj, $2=case scratch dir
# (holds markers + kill-log). $3=lead-mode: "dies" (Case A — lead dead at reap) or
# "lives" (Case B — lead resolvable throughout).
#
# The "dies" mode keys off a `dead-911` marker. A `poll-count-911` counter is
# bumped once per `gh issue view ... labels` query; on the FIRST such query
# (n==0 -> n==1) the gh stub writes the `dead-911` marker, simulating the lead
# being killed externally after launch (the spawn-time pgid capture has already
# happened) but before the reap. Once `dead-911` exists, list-panes and the
# `ps -o pgid=` arm echo EMPTY so the legacy at-reap lookup yields no pgid.
make_common_stubs() {
  local proj="$1"
  local case_dir="$2"
  local lead_mode="$3"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"
  local killed_marker="$case_dir/killed-911"
  local dead_marker="$case_dir/dead-911"

  cat > "$stub_dir/tmux" <<EOF
#!/bin/bash
KILLED_MARKER="$killed_marker"
DEAD_MARKER="$dead_marker"
LEAD_MODE="$lead_mode"
case "\$1" in
  list-windows)
    # 911 present until its window is killed.
    [ -f "\$KILLED_MARKER" ] && exit 0
    echo "issue-911"
    ;;
  list-panes)
    target=""
    shift
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -t) target="\$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    case "\$target" in
      *issue-911)
        # Lead pid resolvable while alive. In "dies" mode it disappears once the
        # dead marker exists (lead killed externally mid-run).
        if [ "\$LEAD_MODE" = "dies" ] && [ -f "\$DEAD_MARKER" ]; then
          : # empty — pane lead no longer listable
        else
          echo "99911"
        fi
        ;;
      *) echo "99000" ;;
    esac
    ;;
  kill-window)
    target=""
    shift
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -t) target="\$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    case "\$target" in
      *issue-911) : > "\$KILLED_MARKER" ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$stub_dir/tmux"

  # ps stub. The `-o pgid=` arm resolves pane pid 99911 -> process GROUP 88811
  # WHILE the lead is alive. In "dies" mode, once the dead marker exists the lead
  # pid is gone, so `-o pgid= -p 99911` echoes EMPTY (the legacy at-reap lookup
  # finds nothing). The `-eo` arm keeps 911 hot (50%) so stall detection never
  # interferes.
  cat > "$stub_dir/ps" <<EOF
#!/bin/bash
DEAD_MARKER="$dead_marker"
LEAD_MODE="$lead_mode"
mode=""; pid=""; want_pid=0
for arg in "\$@"; do
  case "\$arg" in
    -eo)   mode="eo" ;;
    pgid=) mode="pgid" ;;
    -p)    want_pid=1 ;;
    *)     if [ "\$want_pid" = 1 ]; then pid="\$arg"; want_pid=0; fi ;;
  esac
done
if [ "\$mode" = "pgid" ]; then
  if [ "\$pid" = "99911" ]; then
    if [ "\$LEAD_MODE" = "dies" ] && [ -f "\$DEAD_MARKER" ]; then
      echo ""   # lead dead — legacy at-reap-time lookup resolves no pgid
    else
      echo "88811"
    fi
  else
    echo ""
  fi
elif [ "\$mode" = "eo" ]; then
  echo "99911 1 50.0"
else
  echo "0.0"
fi
EOF
  chmod +x "$stub_dir/ps"

  # kill stub: record every invocation's args to the case's kill-log so we can
  # assert the reap signalled the worker's process GROUP via the stored pgid.
  cat > "$stub_dir/kill" <<EOF
#!/bin/bash
echo "\$*" >> "$case_dir/kill-log"
exit 0
EOF
  chmod +x "$stub_dir/kill"

  cat > "$stub_dir/git" <<'EOF'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"
    slug="${entry##*:}"
    echo "worktree ${STUB_WT_BASE:-/tmp}/wt-${issue}-${slug}"
    echo "HEAD abc123"
    echo "branch refs/heads/feature/${slug}"
    echo ""
  done
fi
EOF
  chmod +x "$stub_dir/git"

  echo "$stub_dir"
}

# gh stub builder. $1=case dir, $2=lead-mode. Mirrors Case F's transition-modeling
# stub: 911 labels are `in-progress` for poll 1's two label queries (sets the #694
# SAW_OFF_PR_OPEN witness) and `pr-open` thereafter, no manual-merge, no Evaluation
# comment — so only executor_finished_terminal can free 911 (grace=2 → reap fires
# on poll 3). In "dies" mode the FIRST label query writes the `dead-911` marker so
# the lead is gone before the reap.
write_gh_stub() {
  local case_dir="$1"
  local lead_mode="$2"
  cat > "$case_dir/proj/stub/gh" <<EOF
#!/bin/bash
ARGS="\$*"
CNT_FILE="$case_dir/poll-count-911"
DEAD_MARKER="$case_dir/dead-911"
LEAD_MODE="$lead_mode"
case "\$1 \$2" in
  "issue view")
    issue="\$3"
    if [[ "\$ARGS" == *labels* ]]; then
      if [ "\$issue" = "911" ]; then
        n=\$(cat "\$CNT_FILE" 2>/dev/null || echo 0); echo \$((n+1)) > "\$CNT_FILE"
        # On the first label query, simulate the lead being killed externally
        # (spawn-time capture has already run; reap is still polls away).
        if [ "\$LEAD_MODE" = "dies" ] && [ "\$n" = 0 ]; then : > "\$DEAD_MARKER"; fi
        if [ "\$n" -lt 2 ]; then echo "in-progress"; else echo "pr-open"; fi
      else echo ""; fi
    fi
    ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
  chmod +x "$case_dir/proj/stub/gh"
}

# Run the queue runner for one case and capture output. $1=proj, $2=case dir,
# $3=timeout seconds. stdin from /dev/null so a stray interactive read can't hang.
run_case() {
  local proj="$1"
  local case_dir="$2"
  local tmo="$3"
  (
    cd "$proj"
    PATH="$proj/stub:$PATH" \
      TMUX="fake" \
      STUB_WORKTREES="911:exec" \
      POLL_SECONDS=1 \
      STATUS_INTERVAL=999 \
      PIPELINE_EXECUTOR_REAP_GRACE_POLLS=2 \
      PIPELINE_REAP_SIGKILL_GRACE_SEC=0 \
      BASH_ENV="$proj/.bash_env" \
      PIPELINE_PROJECT_ROOT="$proj" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      timeout "$tmo" bash .claude/scripts/run-queue.sh 911 </dev/null
  ) > "$case_dir/queue.log" 2>&1 || true
}

# ============ Case A: dead-lead reap via the STORED pgid ============
echo "Case A: reap tears down the worker group via the spawn-stored pgid even when the lead is dead"
CASE_A="$ROOT/caseA"; mkdir -p "$CASE_A"
PROJ_A="$CASE_A/proj"
setup_proj "$PROJ_A"
make_common_stubs "$PROJ_A" "$CASE_A" "dies" >/dev/null
write_gh_stub "$CASE_A" "dies"
run_case "$PROJ_A" "$CASE_A" 30

inc
if [ -f "$CASE_A/dead-911" ]; then
  pass_msg "A0: the pane lead was killed externally before the reap (dead-911 marker present)"
else
  fail_msg "A0: expected the dead-911 marker (lead never simulated as killed)"
fi
inc
if grep -q -- '-TERM -88811' "$CASE_A/kill-log" 2>/dev/null \
   && grep -q -- '-KILL -88811' "$CASE_A/kill-log" 2>/dev/null; then
  pass_msg "A1: reap SIGTERM+SIGKILLs the stored process group 88811 despite the dead lead"
else
  fail_msg "A1: expected kill -TERM -88811 then kill -KILL -88811 via the STORED pgid"
  sed 's/^/    kill-log: /' "$CASE_A/kill-log" >&2 2>/dev/null || echo "    (no kill-log)" >&2
fi
inc
if [ -f "$CASE_A/killed-911" ]; then
  pass_msg "A2: reap still force-closes 911's tmux window"
else
  fail_msg "A2: expected tmux kill-window for issue-911"
fi

# ============ Case B: live-lead reap still works (regression guard) ============
echo ""
echo "Case B: live-lead reap still kills the group (fallback + common-case guard)"
CASE_B="$ROOT/caseB"; mkdir -p "$CASE_B"
PROJ_B="$CASE_B/proj"
setup_proj "$PROJ_B"
make_common_stubs "$PROJ_B" "$CASE_B" "lives" >/dev/null
write_gh_stub "$CASE_B" "lives"
run_case "$PROJ_B" "$CASE_B" 30

inc
if grep -q -- '-TERM -88811' "$CASE_B/kill-log" 2>/dev/null \
   && grep -q -- '-KILL -88811' "$CASE_B/kill-log" 2>/dev/null; then
  pass_msg "B1: reap SIGTERM+SIGKILLs the worker process group 88811 (lead alive)"
else
  fail_msg "B1: expected kill -TERM -88811 then kill -KILL -88811"
  sed 's/^/    kill-log: /' "$CASE_B/kill-log" >&2 2>/dev/null || echo "    (no kill-log)" >&2
fi
inc
if [ -f "$CASE_B/killed-911" ]; then
  pass_msg "B2: reap still force-closes 911's tmux window"
else
  fail_msg "B2: expected tmux kill-window for issue-911"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
