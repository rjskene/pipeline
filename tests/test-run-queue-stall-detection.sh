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
  # The poll loop invokes queue-status.sh every STATUS_INTERVAL polls; copy it
  # so the call resolves (we also push STATUS_INTERVAL high to avoid it firing).
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

  # ps stub: `ps -eo pid=,ppid=,%cpu=` — emits a fake process tree per poll.
  # Each call advances a counter and looks up the next scripted value from
  # $CPU_SEQ; the value is assigned to a *descendant* of pane_pid 90100 (the
  # `claude` leaf), while pane_pid itself (the `timeout` supervisor) sits at
  # 0.0. This exercises the subtree-summing fix: a pane_pid-only read would
  # always see 0.0 and break the assertions, but a subtree sum correctly
  # surfaces the descendant's CPU.
  cat > "$stub_dir/ps" <<EOF
#!/bin/bash
CPU_COUNTER="$cpu_counter"
CPU_SEQ="$cpu_seq"
mode=""
for arg in "\$@"; do
  case "\$arg" in
    -eo) mode="eo" ;;
  esac
done
if [ "\$mode" = "eo" ]; then
  n=\$(cat "\$CPU_COUNTER" 2>/dev/null || echo 0)
  n=\$((n + 1))
  echo "\$n" > "\$CPU_COUNTER"
  val=\$(sed -n "\${n}p" "\$CPU_SEQ")
  val="\${val:-0.0}"
  # Process tree: pane_pid → claude descendant carrying the scripted %CPU.
  # 90100 is issue 901's pane (the supervisor at 0.0).
  # 90101 is its claude descendant (where the work lives).
  # 90200 is issue 902's pane; gone after poll 1, so descendant value is moot.
  echo "90100 1 0.0"
  echo "90101 90100 \$val"
  echo "90200 1 0.0"
  echo "90201 90200 0.0"
else
  # Defensive fallback for any non-"-eo" call (e.g. queue-status.sh).
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
    PIPELINE_STALL_SAMPLES_PER_POLL=1 \
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

# ---- Test 2: get_agent_cpu_pct sums pane_pid subtree (the eval-flagged bug) ----
#
# Regression guard for the #437 evaluator's flag: pane_pid is the `timeout`
# (or `script`) supervisor and always reports ~0% CPU. Reading just pane_pid
# would mark every healthy worker stalled. This test feeds a snapshot where
# pane_pid sits at 0.0 and its `claude` descendant carries 42.5%, then asserts
# get_agent_cpu_pct returns 42.5 (sum of subtree) — NOT 0.0 (pane-only read).
echo ""
echo "Test 2: get_agent_cpu_pct sums pane_pid subtree (not pane_pid alone)"
inc
PROJ2="$WORKDIR/p2"
setup_proj "$PROJ2"
STUB_DIR2=$(make_stubs "$PROJ2")

# Snapshot: pane_pid=99100 ppid=1 cpu=0.0 (timeout); descendant 99101 cpu=42.5;
# grandchild 99102 cpu=7.5. Subtree sum = 50.0. An unrelated process 99999
# at 99.9% must NOT contribute.
SNAPSHOT='99100 1 0.0
99101 99100 42.5
99102 99101 7.5
99999 1 99.9'

# Override the tmux list-panes stub to return 99100 for issue 999. The make_stubs
# tmux already returns issue-901/902 pids; extend it via a one-off shim.
cat > "$STUB_DIR2/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  list-panes)
    target=""
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    case "$target" in
      *issue-999) echo "99100" ;;
      *)          echo "" ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB_DIR2/tmux"

RESULT=$(
  PATH="$STUB_DIR2:$PATH" \
  TMUX="fake" \
  PIPELINE_TMUX_SESSION="fake" \
  bash -c '
    source "'"$PROJ2"'/.claude/scripts/_logging.sh" 2>/dev/null || true
    # Pull get_agent_cpu_pct out of run-queue.sh without running its top-level
    # poll-loop side effects. The function lives between two unique sentinels.
    awk "/^get_agent_cpu_pct\\(\\) \\{/,/^\\}$/" "'"$PROJ2"'/.claude/scripts/run-queue.sh" > /tmp/cpu-fn-$$.sh
    source /tmp/cpu-fn-$$.sh
    rm -f /tmp/cpu-fn-$$.sh
    get_agent_cpu_pct 999 "'"$SNAPSHOT"'"
  '
)

# Expected: 0.0 + 42.5 + 7.5 = 50.0. Unrelated 99999@99.9 must be excluded.
if [ "$RESULT" = "50.0" ]; then
  pass_msg "subtree sum = 50.0 (pane_pid + 2 descendants, unrelated pid excluded)"
else
  fail_msg "expected '50.0', got '$RESULT' — subtree summing or pane-pid scoping is broken"
fi

# ---- Test 3: low-but-nonzero subtree CPU latches when below threshold --------
#
# Regression guard for issue #464 (the #456 wedge). A wedged worker's parent
# `claude` was draining a stuck bash subprocess's pipe at ~2% CPU, so the
# subtree aggregate stayed non-zero and the strict `-eq 0` latch test reset on
# every poll — the stall was never surfaced. This test scripts a steady 2.0%
# subtree CPU and asserts the latch still fires (exactly once) when
# PIPELINE_STALL_CPU_THRESHOLD=5 treats <= 5% as idle.
#
# Two active issues are required: run-queue.sh short-circuits a SINGLE issue to
# a direct launch with NO poll loop (and therefore no stall detection). So 903
# is the staller and 904 is a companion that finishes on the first poll (its
# window never appears in list-windows), mirroring Test 1's 901/902 shape.
# With PIPELINE_STALL_POLL_THRESHOLD=3 the latch fires on the 3rd consecutive
# low-CPU poll; STALL_LATCHED keeps it to a single emission until recovery (the
# window then vanishes, ending the loop). Fresh issue/pid numbers (903/904,
# 90300+90301) avoid colliding with Test 1's 901/902 counter files.
echo ""
echo "Test 3: low-but-nonzero subtree CPU (2%) latches when <= PIPELINE_STALL_CPU_THRESHOLD"
inc
PROJ3="$WORKDIR/p3"
setup_proj "$PROJ3"
STUB_DIR3=$(make_stubs "$PROJ3")  # scaffolds gh/git; ps + tmux overridden below.

cpu_counter3="$WORKDIR/ps-counter-903"
cpu_seq3="$WORKDIR/ps-sequence-903"
win_counter3="$WORKDIR/win-counter-903"
echo 0 > "$cpu_counter3"
echo 0 > "$win_counter3"

# Steady 2.0% on 903's claude descendant across every poll — the #456 wedge.
# Because the value is CONSTANT, the exact ps-call ordering between 903 and 904
# (which advances this shared counter) is irrelevant: every read returns 2.0.
cat > "$cpu_seq3" <<'EOF'
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
EOF

# ps stub: 903's pane_pid 90300 (timeout supervisor) at 0.0; its claude
# descendant 90301 carries the scripted 2.0%. Subtree sum surfaces 2.0, which
# must latch. 904's pane 90400 sits at 0.0 but 904 exits on poll 1 so it never
# accrues the threshold count.
cat > "$STUB_DIR3/ps" <<EOF
#!/bin/bash
CPU_COUNTER="$cpu_counter3"
CPU_SEQ="$cpu_seq3"
mode=""
for arg in "\$@"; do
  case "\$arg" in
    -eo) mode="eo" ;;
  esac
done
if [ "\$mode" = "eo" ]; then
  n=\$(cat "\$CPU_COUNTER" 2>/dev/null || echo 0)
  n=\$((n + 1))
  echo "\$n" > "\$CPU_COUNTER"
  val=\$(sed -n "\${n}p" "\$CPU_SEQ")
  val="\${val:-2.0}"
  echo "90300 1 0.0"
  echo "90301 90300 \$val"
  echo "90400 1 0.0"
else
  echo "0.0"
fi
EOF
chmod +x "$STUB_DIR3/ps"

# tmux stub: issue-903 present for the first 8 list-windows calls, then vanishes
# so the poll loop terminates. issue-904 never appears (finishes poll 1).
# list-panes resolves issue-903 -> 90300 / issue-904 -> 90400 (the pane pids the
# subtree walk starts from).
cat > "$STUB_DIR3/tmux" <<EOF
#!/bin/bash
WIN_COUNTER="$win_counter3"
case "\$1" in
  list-windows)
    n=\$(cat "\$WIN_COUNTER" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "\$WIN_COUNTER"
    if [ "\$n" -le 8 ]; then
      echo "issue-903"
    fi
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
      *issue-903) echo "90300" ;;
      *issue-904) echo "90400" ;;
      *)          echo "90000" ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$STUB_DIR3/tmux"

mkdir -p "/tmp/wt-903-baz" "/tmp/wt-904-qux"
STDOUT_CAPTURE3="$WORKDIR/queue-stdout-903.log"
(
  cd "$PROJ3"
  PATH="$STUB_DIR3:$PATH" \
    TMUX="fake" \
    STUB_WORKTREES="903:baz 904:qux" \
    PIPELINE_LOGS_ENABLED=true \
    POLL_SECONDS=1 \
    STATUS_INTERVAL=10000 \
    PIPELINE_STALL_POLL_THRESHOLD=3 \
    PIPELINE_STALL_CPU_THRESHOLD=5 \
    PIPELINE_STALL_SAMPLES_PER_POLL=1 \
    CLAUDE_PLUGIN_ROOT="$PROJ3/.claude" \
    bash .claude/scripts/run-queue.sh 903 904
) > "$STDOUT_CAPTURE3" 2>&1

# Exactly one latched stall event: 2% stays <= 5% the whole window, so the
# latch arms once and STALL_LATCHED suppresses re-emission until recovery.
# `grep -c` already prints its own 0 on no-match (and exits 1); use `|| true` so
# the count stays single-line — a trailing `|| echo 0` would append a 2nd line.
stall_count3=$(grep -c 'EVENT: agent-stalled issue=903' "$STDOUT_CAPTURE3" 2>/dev/null || true)
if [ "$stall_count3" -eq 1 ]; then
  pass_msg "2% subtree CPU latched once with PIPELINE_STALL_CPU_THRESHOLD=5"
else
  fail_msg "expected exactly 1 'EVENT: agent-stalled issue=903' in stdout, got $stall_count3"
  echo "--- stdout capture ---" >&2
  sed 's/^/    /' "$STDOUT_CAPTURE3" >&2
fi

# ---- Test 4: multi-sample-per-poll suppresses false stalls on bursty CPU -----
#
# Regression guard for issue #592. The runner now takes N=PIPELINE_STALL_SAMPLES_PER_POLL
# `ps` snapshots per poll and feeds the MAX subtree-CPU across those samples into
# the latch logic. Without that fix the runner samples once per poll and routinely
# misses short-lived bash children spawned by `claude` tool calls (ps reports
# lifetime-average %cpu — a Bash subshell caught mid-flight reads near 0).
#
# This test scripts a `ps` stub that returns 0.0 on sample-positions 1 and 3, and
# 12.0 on sample-position 2, within each poll's three-sample window. With the
# fix the max-of-3 per poll is 12.0 (> PIPELINE_STALL_CPU_THRESHOLD=5), so no
# stall ever latches. Without the fix (single-sample), sample 1 (0.0) drives the
# latch and `agent-stalled` fires.
#
# Two active issues so the poll loop runs (single-issue short-circuits skip it).
# 905 is the bursty worker; 906 finishes on poll 1.
echo ""
echo "Test 4: multi-sample max-of-N per poll suppresses false stall on bursty subtree CPU (#592)"
inc
PROJ4="$WORKDIR/p4"
setup_proj "$PROJ4"
STUB_DIR4=$(make_stubs "$PROJ4")  # scaffolds gh/git; ps + tmux overridden below.

cpu_counter4="$WORKDIR/ps-counter-905"
win_counter4="$WORKDIR/win-counter-905"
echo 0 > "$cpu_counter4"
echo 0 > "$win_counter4"

# ps stub: returns 12.0 on every 4th `ps -eo` call (positions 4, 8, 12, ...) and
# 0.0 otherwise. Designed so the two sampling modes diverge:
#
#   Single-sample mode (the bug): one ps-call per poll, so polls 1/2/3 read 0.0
#   (consec_idle reaches 3 → latch fires), poll 4 reads 12.0 (reset), ...
#
#   Multi-sample mode (the fix): three ps-calls per poll. Burst 1 = positions
#   {1,2,3} = {0,0,0} → max=0 → consec_idle=1. Burst 2 = positions {4,5,6} =
#   {12,0,0} → max=12 → reset. Burst 3 = positions {7,8,9} = {0,12,0} → max=12
#   → reset. Burst 4 = positions {10,11,12} = {0,0,12} → max=12 → reset. ...
#   consec_idle never reaches 3, latch never fires.
cat > "$STUB_DIR4/ps" <<EOF
#!/bin/bash
CPU_COUNTER="$cpu_counter4"
mode=""
for arg in "\$@"; do
  case "\$arg" in
    -eo) mode="eo" ;;
  esac
done
if [ "\$mode" = "eo" ]; then
  n=\$(cat "\$CPU_COUNTER" 2>/dev/null || echo 0)
  n=\$((n + 1))
  echo "\$n" > "\$CPU_COUNTER"
  # 12.0 every 4th call; 0.0 otherwise.
  if [ \$(( n % 4 )) -eq 0 ]; then
    val="12.0"
  else
    val="0.0"
  fi
  echo "90500 1 0.0"
  echo "90501 90500 \$val"
  echo "90600 1 0.0"
else
  echo "0.0"
fi
EOF
chmod +x "$STUB_DIR4/ps"

# tmux stub: issue-905 present for the first 8 list-windows calls, then vanishes
# so the poll loop terminates. issue-906 never appears (finishes poll 1).
cat > "$STUB_DIR4/tmux" <<EOF
#!/bin/bash
WIN_COUNTER="$win_counter4"
case "\$1" in
  list-windows)
    n=\$(cat "\$WIN_COUNTER" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "\$WIN_COUNTER"
    if [ "\$n" -le 8 ]; then
      echo "issue-905"
    fi
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
      *issue-905) echo "90500" ;;
      *issue-906) echo "90600" ;;
      *)          echo "90000" ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$STUB_DIR4/tmux"

mkdir -p "/tmp/wt-905-quux" "/tmp/wt-906-corge"
STDOUT_CAPTURE4="$WORKDIR/queue-stdout-905.log"
(
  cd "$PROJ4"
  PATH="$STUB_DIR4:$PATH" \
    TMUX="fake" \
    STUB_WORKTREES="905:quux 906:corge" \
    PIPELINE_LOGS_ENABLED=true \
    POLL_SECONDS=1 \
    STATUS_INTERVAL=10000 \
    PIPELINE_STALL_POLL_THRESHOLD=3 \
    PIPELINE_STALL_CPU_THRESHOLD=5 \
    PIPELINE_STALL_SAMPLES_PER_POLL=3 \
    PIPELINE_STALL_SAMPLE_INTERVAL_SEC=0 \
    CLAUDE_PLUGIN_ROOT="$PROJ4/.claude" \
    bash .claude/scripts/run-queue.sh 905 906
) > "$STDOUT_CAPTURE4" 2>&1

# `grep -c` prints `0` (and exits 1) on no-match. With the fix, max-of-3 = 12.0
# every poll, so NO stall latches; without the fix, latch fires at least once.
stall_count4=$(grep -c 'EVENT: agent-stalled issue=905' "$STDOUT_CAPTURE4" 2>/dev/null || true)
if [ "$stall_count4" -eq 0 ]; then
  pass_msg "max-of-3-samples-per-poll suppressed false stall (bursty subtree CPU, sample-position-2 = 12%)"
else
  fail_msg "expected exactly 0 'EVENT: agent-stalled issue=905' in stdout, got $stall_count4"
  echo "--- stdout capture ---" >&2
  sed 's/^/    /' "$STDOUT_CAPTURE4" >&2
fi

# ---- Test 5: advancing tmux pane at idle CPU suppresses the stall (#641) -----
#
# The #641 false-positive: an API-bound executor/evaluator idles near ~2% subtree
# CPU (it is blocked on the model, not the host), so the #464 idle-CPU pre-filter
# alone latches `agent-stalled` on a perfectly healthy worker. The fix gates the
# latch on forward progress: a low-CPU poll only advances the stall counter if the
# worker's tmux-pane fingerprint is ALSO unchanged since the prior poll. Here the
# pane GROWS every poll (assistant tokens still streaming), so despite steady idle
# CPU the worker must NEVER be flagged.
#
# Two active issues so the poll loop runs (single-issue short-circuits skip it).
# 907 is the healthy API-bound worker (idle CPU + advancing pane); 908 finishes
# on poll 1.
echo ""
echo "Test 5: advancing tmux pane at idle CPU suppresses stall (#641 false-positive fix)"
inc
PROJ7="$WORKDIR/p7"
setup_proj "$PROJ7"
STUB_DIR7=$(make_stubs "$PROJ7")  # scaffolds gh/git; ps + tmux overridden below.

cpu_counter7="$WORKDIR/ps-counter-907"
cpu_seq7="$WORKDIR/ps-sequence-907"
win_counter7="$WORKDIR/win-counter-907"
pane_counter7="$WORKDIR/pane-counter-907"
echo 0 > "$cpu_counter7"
echo 0 > "$win_counter7"
echo 0 > "$pane_counter7"

# Steady 2.0% on 907's claude descendant across every poll — the API-bound idle.
cat > "$cpu_seq7" <<'EOF'
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
EOF

# ps stub: 907's pane_pid 90700 (timeout supervisor) at 0.0; its claude
# descendant 90701 carries the scripted steady 2.0%. 908's pane 90800 sits at
# 0.0 but 908 exits on poll 1 so it never accrues the threshold count.
cat > "$STUB_DIR7/ps" <<EOF
#!/bin/bash
CPU_COUNTER="$cpu_counter7"
CPU_SEQ="$cpu_seq7"
mode=""
for arg in "\$@"; do
  case "\$arg" in
    -eo) mode="eo" ;;
  esac
done
if [ "\$mode" = "eo" ]; then
  n=\$(cat "\$CPU_COUNTER" 2>/dev/null || echo 0)
  n=\$((n + 1))
  echo "\$n" > "\$CPU_COUNTER"
  val=\$(sed -n "\${n}p" "\$CPU_SEQ")
  val="\${val:-2.0}"
  echo "90700 1 0.0"
  echo "90701 90700 \$val"
  echo "90800 1 0.0"
else
  echo "0.0"
fi
EOF
chmod +x "$STUB_DIR7/ps"

# tmux stub: issue-907 present for the first 10 list-windows calls, then vanishes
# so the poll loop terminates. issue-908 never appears (finishes poll 1).
# capture-pane returns a GROWING byte stream keyed on a per-call counter so the
# fingerprint strictly advances poll-over-poll == forward progress observed.
cat > "$STUB_DIR7/tmux" <<EOF
#!/bin/bash
WIN_COUNTER="$win_counter7"
PANE_COUNTER="$pane_counter7"
case "\$1" in
  capture-pane)
    n=\$(cat "\$PANE_COUNTER" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "\$PANE_COUNTER"
    for i in \$(seq 1 "\$n"); do echo "assistant-token-line-\$i"; done
    ;;
  list-windows)
    n=\$(cat "\$WIN_COUNTER" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "\$WIN_COUNTER"
    if [ "\$n" -le 10 ]; then
      echo "issue-907"
    fi
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
      *issue-907) echo "90700" ;;
      *issue-908) echo "90800" ;;
      *)          echo "90000" ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$STUB_DIR7/tmux"

mkdir -p "/tmp/wt-907-grault" "/tmp/wt-908-garply"
STDOUT_CAPTURE7="$WORKDIR/queue-stdout-907.log"
(
  cd "$PROJ7"
  PATH="$STUB_DIR7:$PATH" \
    TMUX="fake" \
    STUB_WORKTREES="907:grault 908:garply" \
    PIPELINE_LOGS_ENABLED=true \
    POLL_SECONDS=1 \
    STATUS_INTERVAL=10000 \
    PIPELINE_STALL_POLL_THRESHOLD=3 \
    PIPELINE_STALL_CPU_THRESHOLD=5 \
    PIPELINE_STALL_SAMPLES_PER_POLL=1 \
    CLAUDE_PLUGIN_ROOT="$PROJ7/.claude" \
    bash .claude/scripts/run-queue.sh 907 908
) > "$STDOUT_CAPTURE7" 2>&1

# Advancing pane == forward progress == healthy. Despite steady 2% idle CPU the
# latch must NEVER arm. `grep -c` prints 0 (exit 1) on no-match; `|| true` keeps
# it single-line.
stall_count7=$(grep -c 'EVENT: agent-stalled issue=907' "$STDOUT_CAPTURE7" 2>/dev/null || true)
if [ "$stall_count7" -eq 0 ]; then
  pass_msg "advancing pane suppressed stall at idle CPU (healthy API-bound worker)"
else
  fail_msg "expected 0 stall events for healthy advancing-pane worker, got $stall_count7"
  echo "--- stdout capture ---" >&2
  sed 's/^/    /' "$STDOUT_CAPTURE7" >&2
fi

# ---- Test 6: true wedge (idle CPU + FROZEN pane) still latches once (#641) ----
#
# True-positive guard for the #641 fix. A genuine wedge is idle CPU AND a frozen
# pane (no output across the window) — exactly the #456-family stall the runner
# must still surface. Here capture-pane returns a CONSTANT string every poll, so
# the fingerprint never changes == no forward progress; with steady 2% idle CPU
# the latch must arm EXACTLY once (STALL_LATCHED suppresses re-emission). The
# one-poll first-idle grace shifts the latch one poll later than the pure CPU
# path, so issue-909's window stays present long enough to clear threshold+grace.
#
# 909 is the wedged worker (idle CPU + frozen pane); 910 finishes on poll 1.
echo ""
echo "Test 6: frozen tmux pane at idle CPU still latches stall once (#641 true-positive preserved)"
inc
PROJ9="$WORKDIR/p9"
setup_proj "$PROJ9"
STUB_DIR9=$(make_stubs "$PROJ9")  # scaffolds gh/git; ps + tmux overridden below.

cpu_counter9="$WORKDIR/ps-counter-909"
cpu_seq9="$WORKDIR/ps-sequence-909"
win_counter9="$WORKDIR/win-counter-909"
echo 0 > "$cpu_counter9"
echo 0 > "$win_counter9"

# Steady 2.0% on 909's claude descendant across every poll — idle CPU.
cat > "$cpu_seq9" <<'EOF'
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
2.0
EOF

cat > "$STUB_DIR9/ps" <<EOF
#!/bin/bash
CPU_COUNTER="$cpu_counter9"
CPU_SEQ="$cpu_seq9"
mode=""
for arg in "\$@"; do
  case "\$arg" in
    -eo) mode="eo" ;;
  esac
done
if [ "\$mode" = "eo" ]; then
  n=\$(cat "\$CPU_COUNTER" 2>/dev/null || echo 0)
  n=\$((n + 1))
  echo "\$n" > "\$CPU_COUNTER"
  val=\$(sed -n "\${n}p" "\$CPU_SEQ")
  val="\${val:-2.0}"
  echo "90900 1 0.0"
  echo "90901 90900 \$val"
  echo "91000 1 0.0"
else
  echo "0.0"
fi
EOF
chmod +x "$STUB_DIR9/ps"

# tmux stub: issue-909 present for the first 8 list-windows calls, then vanishes.
# capture-pane returns a CONSTANT string every call (frozen pane) -> fingerprint
# never changes -> no forward progress -> the wedge latches.
cat > "$STUB_DIR9/tmux" <<EOF
#!/bin/bash
WIN_COUNTER="$win_counter9"
case "\$1" in
  capture-pane)
    echo "wedged sleep-poll: gh pr list --head feature/foo (no change)"
    ;;
  list-windows)
    n=\$(cat "\$WIN_COUNTER" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "\$WIN_COUNTER"
    if [ "\$n" -le 8 ]; then
      echo "issue-909"
    fi
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
      *issue-909) echo "90900" ;;
      *issue-910) echo "91000" ;;
      *)          echo "90000" ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$STUB_DIR9/tmux"

mkdir -p "/tmp/wt-909-waldo" "/tmp/wt-910-fred"
STDOUT_CAPTURE9="$WORKDIR/queue-stdout-909.log"
(
  cd "$PROJ9"
  PATH="$STUB_DIR9:$PATH" \
    TMUX="fake" \
    STUB_WORKTREES="909:waldo 910:fred" \
    PIPELINE_LOGS_ENABLED=true \
    POLL_SECONDS=1 \
    STATUS_INTERVAL=10000 \
    PIPELINE_STALL_POLL_THRESHOLD=3 \
    PIPELINE_STALL_CPU_THRESHOLD=5 \
    PIPELINE_STALL_SAMPLES_PER_POLL=1 \
    CLAUDE_PLUGIN_ROOT="$PROJ9/.claude" \
    bash .claude/scripts/run-queue.sh 909 910
) > "$STDOUT_CAPTURE9" 2>&1

# Frozen pane at idle CPU == genuine wedge. Latch arms exactly once.
stall_count9=$(grep -c 'EVENT: agent-stalled issue=909' "$STDOUT_CAPTURE9" 2>/dev/null || true)
if [ "$stall_count9" -eq 1 ]; then
  pass_msg "frozen pane at idle CPU still latches once (true wedge preserved)"
else
  fail_msg "expected exactly 1 stall event for frozen-pane wedge, got $stall_count9"
  echo "--- stdout capture ---" >&2
  sed 's/^/    /' "$STDOUT_CAPTURE9" >&2
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
