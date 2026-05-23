#!/bin/bash
set -uo pipefail

# Tests that scripts/run-queue.sh emits a latched `EVENT: agent-stalled` line
# when a worker idles at 0% CPU across PIPELINE_STALL_POLL_THRESHOLD polls.
# The runner takes NO kill action — it only observes and reports.
#
# Strategy: drive the FULL poll loop (non-dry-run) with two active issues.
# - Issue 901 stalls: its tmux window stays present and `ps` returns 0.0% CPU
#   for a stall window, recovers once (12.3%), then re-stalls.
# - Issue 902 finishes on the first poll (its window never appears in
#   list-windows) so it never contributes to the shared `ps` counter.
#
# The `ps` stub is scripted via a counter file in $WORKDIR so successive
# invocations return a deterministic CPU sequence. A sentinel file makes the
# stalling window's name disappear once enough stall events have been emitted,
# letting the poll loop terminate.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/run-queue.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs"
  cp "$SCRIPT_UNDER_TEST" "$proj/.claude/scripts/run-queue.sh"
  cp "$REPO_ROOT/scripts/_logging.sh" "$proj/.claude/scripts/_logging.sh"
  # run-queue.sh sources _resolve-container-var.sh from SCRIPT_DIR (#336).
  cp "$REPO_ROOT/scripts/_resolve-container-var.sh" "$proj/.claude/scripts/_resolve-container-var.sh"
  # The poll loop invokes queue-status.sh every STATUS_INTERVAL polls; copy it
  # so the call resolves (we also push STATUS_INTERVAL high to avoid it firing).
  cp "$REPO_ROOT/scripts/queue-status.sh" "$proj/.claude/scripts/queue-status.sh"
  cp "$REPO_ROOT/scripts/eval-classifier-invoke.sh" "$proj/.claude/scripts/eval-classifier-invoke.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh" "$proj/.claude/scripts/queue-status.sh" \
    "$proj/.claude/scripts/eval-classifier-invoke.sh"
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

# CPU sequence file: each line is the %CPU returned by the Nth `ps` call for
# the stalling issue. We want:
#   polls 1..N (>= threshold)  -> 0.0  (first stall, latches once)
#   one poll                   -> 12.3 (recovery, resets latch)
#   polls ..N (>= threshold)   -> 0.0  (re-stall, latches again)
# With threshold=3 and POLL_SECONDS=1, a sequence of:
#   0.0 0.0 0.0 0.0   (stall + latch on the 3rd)
#   12.3              (recovery)
#   0.0 0.0 0.0 0.0   (re-stall + latch on the 3rd)
# then the window vanishes. We pad with trailing 0.0 to be safe.

make_stubs() {
  local proj="$1"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"

  local cpu_counter="$WORKDIR/ps-counter-901"
  local cpu_seq="$WORKDIR/ps-sequence-901"
  local win_counter="$WORKDIR/win-counter"
  echo 0 > "$cpu_counter"
  echo 0 > "$win_counter"

  # CPU sequence for issue 901's pid (one value per line, 1-indexed). The poll
  # loop calls get_agent_cpu_pct once per active issue per poll. By keying the
  # ps stub on the pid, only 901's calls consume this sequence; 902 (which is
  # also briefly active on the first poll, ordering-dependent) gets a different
  # pid and never touches it. With threshold=3:
  #   0.0 0.0 0.0 0.0  -> first stall, latches on the 3rd consecutive zero
  #   12.3             -> recovery, clears the latch
  #   0.0 0.0 0.0 0.0  -> re-stall, latches again
  cat > "$cpu_seq" <<'EOF'
0.0
0.0
0.0
0.0
12.3
0.0
0.0
0.0
0.0
0.0
0.0
0.0
EOF

  # ps stub: `ps -o %cpu= -p <pid>`. Only pid 901xx draws from the 901
  # sequence; any other pid always reports 0.0 (902 is gone after poll 1 so
  # its CPU history is irrelevant).
  cat > "$stub_dir/ps" <<EOF
#!/bin/bash
CPU_COUNTER="$cpu_counter"
CPU_SEQ="$cpu_seq"
pid=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -p) pid="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
if [ "\$pid" = "90100" ]; then
  n=\$(cat "\$CPU_COUNTER" 2>/dev/null || echo 0)
  n=\$((n + 1))
  echo "\$n" > "\$CPU_COUNTER"
  val=\$(sed -n "\${n}p" "\$CPU_SEQ")
  echo "\${val:-0.0}"
else
  echo "0.0"
fi
EOF
  chmod +x "$stub_dir/ps"

  # tmux stub:
  #   list-windows -t <session> -F '#{window_name}'  -> active window names
  #   list-panes   -t <session>:issue-<N> -F '#{pane_pid}' -> a pid keyed on N
  # 902 never appears in list-windows (finishes on the first poll). 901 appears
  # for the first ~11 list-windows calls (one per poll), then vanishes so the
  # poll loop terminates. This gate is independent of the ps counter, so the
  # loop is guaranteed to terminate even when stall detection is NOT yet
  # implemented (the RED phase) — list-windows is called once per active issue
  # per poll regardless.
  cat > "$stub_dir/tmux" <<EOF
#!/bin/bash
WIN_COUNTER="$win_counter"
case "\$1" in
  list-windows)
    n=\$(cat "\$WIN_COUNTER" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "\$WIN_COUNTER"
    if [ "\$n" -le 11 ]; then
      echo "issue-901"
    fi
    ;;
  list-panes)
    # Resolve the issue number from the -t <session>:issue-<N> target and
    # return a deterministic, per-issue pid: issue 901 -> 90100, 902 -> 90200.
    target=""
    shift
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -t) target="\$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    case "\$target" in
      *issue-901) echo "90100" ;;
      *issue-902) echo "90200" ;;
      *)          echo "90000" ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
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

# ---- Test 1: latched agent-stalled emission across a stall/recovery/re-stall ----
echo "Test 1: 0% CPU across threshold polls emits latched EVENT: agent-stalled (x2)"
inc
PROJ="$WORKDIR/p1"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
for entry in 901:foo 902:bar; do
  issue="${entry%%:*}"; slug="${entry##*:}"
  mkdir -p "/tmp/wt-${issue}-${slug}"
done
STDOUT_CAPTURE="$WORKDIR/queue-stdout.log"
(
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    TMUX="fake" \
    STUB_WORKTREES="901:foo 902:bar" \
    PIPELINE_LOGS_ENABLED=true \
    POLL_SECONDS=1 \
    STATUS_INTERVAL=10000 \
    PIPELINE_STALL_POLL_THRESHOLD=3 \
    CLAUDE_PLUGIN_ROOT="$PROJ/.claude" \
    bash .claude/scripts/run-queue.sh 901 902
) > "$STDOUT_CAPTURE" 2>&1

QUEUE_LOG=$(ls -t "$PROJ/.claude/logs/"queue-*.log 2>/dev/null | head -1)

ok=1

# Assertion A (captured stdout): exactly two stall events for issue 901.
stdout_count=$(grep -c 'EVENT: agent-stalled issue=901' "$STDOUT_CAPTURE" 2>/dev/null || echo 0)
if [ "$stdout_count" -ne 2 ]; then
  fail_msg "expected exactly 2 'EVENT: agent-stalled issue=901' in stdout, got $stdout_count"
  echo "--- stdout capture ---" >&2
  sed 's/^/    /' "$STDOUT_CAPTURE" >&2
  ok=0
fi

# Assertion B (tee path): the queue log mirrors the same two events.
if [ "$ok" = "1" ]; then
  if [ -z "$QUEUE_LOG" ] || [ ! -f "$QUEUE_LOG" ]; then
    fail_msg "queue log not found (PIPELINE_LOGS_ENABLED=true should create it)"
    ok=0
  else
    log_count=$(grep -c 'EVENT: agent-stalled issue=901' "$QUEUE_LOG" 2>/dev/null || echo 0)
    if [ "$log_count" -ne 2 ]; then
      fail_msg "expected 2 'EVENT: agent-stalled issue=901' in queue log, got $log_count"
      ok=0
    fi
  fi
fi

# Assertion C (field shape): first stall line carries pid/window/elapsed fields.
if [ "$ok" = "1" ]; then
  first_line=$(grep -m1 'EVENT: agent-stalled issue=901' "$STDOUT_CAPTURE")
  if ! echo "$first_line" | grep -qE 'pid=[0-9?]+ window=issue-901 elapsed=[0-9]+m'; then
    fail_msg "first agent-stalled line missing pid=/window=/elapsed= shape: $first_line"
    ok=0
  fi
fi

[ "$ok" = "1" ] && pass_msg "latched agent-stalled emitted twice (stall, recover, re-stall); fields well-formed"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
