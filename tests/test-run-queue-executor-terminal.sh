#!/bin/bash
set -uo pipefail

# Tests scripts/run-queue.sh executor_finished_terminal() reap: a worker that
# opened a PR + applied the `pr-open` label but whose spawned `claude` child
# lingers, holding the worktree + a concurrency slot (issue #636).
#
# Strategy mirrors test-run-queue-evaluator-terminal.sh: drive the FULL poll
# loop (non-dry-run) with a two-issue queue (911 + 912). Issue 912 finishes on
# the first poll (its window never appears in list-windows) so it exercises the
# existing is_agent_running==false branch. Issue 911 is the wedged executor: its
# tmux window stays present and its CPU stays healthy (50%), so ONLY the new
# executor_finished_terminal() predicate + grace-gated reap branch can free its
# slot. Each case runs in its own scratch dir so stub state (kill markers) does
# not leak between cases. The new per-case knob is the reap grace window
# (PIPELINE_EXECUTOR_REAP_GRACE_POLLS) passed into run_case.
#
# Four sub-cases:
#   A — reap after grace (grace=2). 911 sits at `pr-open` on every poll; the
#       evaluator predicate cannot fire (no manual-merge label, no linked-PR
#       Evaluation comment), so only the executor predicate frees 911 once the
#       grace window elapses.
#   B — grace NOT yet elapsed (grace=999). Identical gh stub to A, but the
#       grace threshold is unreachable within the short timeout, so the reap
#       must NOT fire (the worker is preserved while the grace window is open).
#   C — fail-closed: `pr-open` absent (grace=2). 911 sits at `in-progress`; the
#       executor predicate must never fire so the counter never advances.
#   D — merged supersedes `pr-open` (grace=2). 911 carries `merged,pr-open`; the
#       predicate's merged arm must short-circuit so the executor reap path does
#       NOT record a bare outcome=pr-open (the merged case is owned by the
#       existing is_agent_running / check_issue_outcome branches).
#
# Expected on first run (RED, before the predicate + reap branch are wired):
# A1-A3 fail (911 never freed, runner reaped by `timeout`); B/C/D pass
# coincidentally and stand as regression guards once the impl lands.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/run-queue.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT=$(mktemp -d)
# Worktree dirs find_worktree() existence-checks; shared across cases (dirs only
# need to exist). STUB_WORKTREES drives the git stub's `worktree list` output.
mkdir -p "/tmp/wt-911-exec" "/tmp/wt-912-bar"
trap 'rm -rf "$ROOT" "/tmp/wt-911-exec" "/tmp/wt-912-bar"' EXIT

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
  # `kill` is a bash BUILTIN, so a PATH stub alone cannot intercept the reap's
  # process-group signals. BASH_ENV (sourced by every non-interactive bash,
  # including run-queue.sh) disables the builtin so `kill` resolves to the PATH
  # stub and Case F can observe the signalled pgid. Harmless to the other stubs.
  cat > "$proj/.bash_env" <<'EOF'
enable -n kill 2>/dev/null || true
EOF
  # Post-#514 route_issue() unconditionally maps to mode=bare with no gh
  # round-trip, so the only gh traffic in the loop is the new predicate.
  cat > "$proj/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
EOF
}

# tmux + ps + git stubs shared by all cases. $1=proj, $2=case scratch dir
# (holds the kill marker). 911's window is present until kill-window fires; once
# the marker exists, list-windows stops printing it (the slot is freed). 911's
# CPU stays healthy (50%) so stall detection never interferes. 912 never appears
# in list-windows, so it finishes on poll 1 via the existing is_agent_running
# branch.
make_common_stubs() {
  local proj="$1"
  local case_dir="$2"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"
  local killed_marker="$case_dir/killed-911"

  cat > "$stub_dir/tmux" <<EOF
#!/bin/bash
KILLED_MARKER="$killed_marker"
case "\$1" in
  list-windows)
    # 911 present until its window is killed; 912 never present.
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
      *issue-911) echo "99911" ;;
      *issue-912) echo "99912" ;;
      *)          echo "99000" ;;
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

  # ps stub: 911's pane pid 99911 runs hot (50%) so the subtree-sum stall check
  # never flags it. The `-o pgid=` arm resolves pane pid 99911 to a fixed process
  # GROUP id (88811) for the reap helper (issue #666); any other `-o pgid=` pid
  # echoes empty so the helper's "no pgid -> skip kill" fail-safe is exercised.
  cat > "$stub_dir/ps" <<'EOF'
#!/bin/bash
mode=""; pid=""; want_pid=0
for arg in "$@"; do
  case "$arg" in
    -eo)   mode="eo" ;;
    pgid=) mode="pgid" ;;
    -p)    want_pid=1 ;;
    *)     if [ "$want_pid" = 1 ]; then pid="$arg"; want_pid=0; fi ;;
  esac
done
if [ "$mode" = "pgid" ]; then
  if [ "$pid" = "99911" ]; then echo "88811"; else echo ""; fi
elif [ "$mode" = "eo" ]; then
  echo "99911 1 50.0"
else
  echo "0.0"
fi
EOF
  chmod +x "$stub_dir/ps"

  # kill stub: record every invocation's args (`"$*"`) to the case's kill-log so
  # Case F can assert the reap signalled the worker's process GROUP. Real signals
  # would no-op against the stubbed pgid anyway; recording keeps the assertion
  # hermetic.
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

# Run the queue runner for one case and capture stdout. $1=proj, $2=case dir,
# $3=timeout seconds, $4=grace polls (PIPELINE_EXECUTOR_REAP_GRACE_POLLS),
# $5=extra runner args (optional, word-split before the issue numbers; e.g.
# `--skill evaluate-issue-pr`). EVENT lines go to stdout unconditionally
# (logging-off path), so we grep the captured stdout — no queue-*.log file
# needed.
run_case() {
  local proj="$1"
  local case_dir="$2"
  local tmo="$3"
  local grace_polls="$4"
  local extra_args="${5:-}"
  (
    cd "$proj"
    PATH="$proj/stub:$PATH" \
      TMUX="fake" \
      STUB_WORKTREES="911:exec 912:bar" \
      POLL_SECONDS=1 \
      STATUS_INTERVAL=999 \
      PIPELINE_EXECUTOR_REAP_GRACE_POLLS="$grace_polls" \
      PIPELINE_REAP_SIGKILL_GRACE_SEC=0 \
      BASH_ENV="$proj/.bash_env" \
      PIPELINE_PROJECT_ROOT="$proj" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      timeout "$tmo" bash .claude/scripts/run-queue.sh $extra_args 911 912
  ) > "$case_dir/queue.log" 2>&1 || true
}

# ===================== Case A: reap after grace window =====================
echo "Case A: executor lingering at pr-open is reaped after the grace window"
CASE_A="$ROOT/caseA"; mkdir -p "$CASE_A"
PROJ_A="$CASE_A/proj"
setup_proj "$PROJ_A"
STUB_A=$(make_common_stubs "$PROJ_A" "$CASE_A")
# gh stub: 911 labels model a real executor transition for the #694 witness gate
# — `in-progress` for poll 1's label queries, `pr-open` on every subsequent query
# (no manual-merge, not merged); 912 returns empty. The runner makes exactly TWO
# `gh issue view ... labels` queries per poll for an active worker
# (evaluator_finished_terminal then executor_finished_terminal — each calls it
# once; the executor predicate is evaluated a single time per poll), so the first
# 2 queries == poll 1. Returning `in-progress` for n<2 keeps BOTH of poll 1's
# queries off pr-open, which sets SAW_OFF_PR_OPEN (the worker is witnessed
# transitioning in-progress -> pr-open). Polls 2-3 then drive the contiguous
# pr-open grace window (grace=2) and the reap fires on poll 3. WHY this must be
# non-pr-open on the first poll: under the #694 transition gate a worker that is
# pr-open from poll 1 models an EVALUATOR and is never reaped; without modelling
# the transition this executor-reap case would silently stop firing (false-green).
# The evaluator predicate must NOT fire (no manual-merge label, and `pr view`
# returns no Evaluation comment), so only executor_finished_terminal can free 911.
cat > "$STUB_A/gh" <<EOF
#!/bin/bash
ARGS="\$*"
CNT_FILE="$CASE_A/poll-count-911"
case "\$1 \$2" in
  "issue view")
    issue="\$3"
    if [[ "\$ARGS" == *labels* ]]; then
      if [ "\$issue" = "911" ]; then
        n=\$(cat "\$CNT_FILE" 2>/dev/null || echo 0); echo \$((n+1)) > "\$CNT_FILE"
        if [ "\$n" -lt 2 ]; then echo "in-progress"; else echo "pr-open"; fi
      else echo ""; fi
    fi
    ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_A/gh"
run_case "$PROJ_A" "$CASE_A" 30 2

inc
if grep -q 'EVENT: agent-finished issue=911 outcome=pr-open' "$CASE_A/queue.log"; then
  pass_msg "A1: runner emits agent-finished outcome=pr-open for 911 after grace"
else
  fail_msg "A1: expected agent-finished outcome=pr-open for 911"
  sed 's/^/    /' "$CASE_A/queue.log" >&2
fi
inc
if [ -f "$CASE_A/killed-911" ]; then
  pass_msg "A2: runner force-closed 911's tmux window"
else
  fail_msg "A2: expected tmux kill-window for issue-911 (no killed-911 marker)"
fi
inc
if grep -q 'EVENT: queue-complete total=2' "$CASE_A/queue.log"; then
  pass_msg "A3: queue reaches queue-complete without waiting out the wedge"
else
  fail_msg "A3: expected EVENT: queue-complete total=2"
fi

# ===================== Case B: grace NOT yet elapsed =====================
echo ""
echo "Case B: grace window not yet elapsed -> worker preserved (no premature reap)"
CASE_B="$ROOT/caseB"; mkdir -p "$CASE_B"
PROJ_B="$CASE_B/proj"
setup_proj "$PROJ_B"
STUB_B=$(make_common_stubs "$PROJ_B" "$CASE_B")
# Identical gh stub to Case A (911 always pr-open). With grace=999 unreachable
# inside the short timeout, the reap must NOT fire.
cat > "$STUB_B/gh" <<'EOF'
#!/bin/bash
ARGS="$*"
case "$1 $2" in
  "issue view")
    issue="$3"
    if [[ "$ARGS" == *labels* ]]; then
      if [ "$issue" = "911" ]; then echo "pr-open"; else echo ""; fi
    fi
    ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_B/gh"
run_case "$PROJ_B" "$CASE_B" 6 999

inc
if ! grep -q 'EVENT: agent-finished issue=911 outcome=pr-open' "$CASE_B/queue.log"; then
  pass_msg "B1: no reap while the grace window is still open"
else
  fail_msg "B1: predicate reaped 911 before the grace window elapsed"
  sed 's/^/    /' "$CASE_B/queue.log" >&2
fi
inc
if [ ! -f "$CASE_B/killed-911" ]; then
  pass_msg "B2: runner did NOT kill 911's window while grace open"
else
  fail_msg "B2: runner force-closed 911 before the grace window elapsed"
fi

# ================= Case C: fail-closed when pr-open absent =================
echo ""
echo "Case C: pr-open label absent -> predicate fail-closed, worker NOT reaped"
CASE_C="$ROOT/caseC"; mkdir -p "$CASE_C"
PROJ_C="$CASE_C/proj"
setup_proj "$PROJ_C"
STUB_C=$(make_common_stubs "$PROJ_C" "$CASE_C")
# gh stub: 911 labels return `in-progress` (no pr-open); 912 empty. The executor
# predicate must never fire, so the counter never advances.
cat > "$STUB_C/gh" <<'EOF'
#!/bin/bash
ARGS="$*"
case "$1 $2" in
  "issue view")
    issue="$3"
    if [[ "$ARGS" == *labels* ]]; then
      if [ "$issue" = "911" ]; then echo "in-progress"; else echo ""; fi
    fi
    ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_C/gh"
run_case "$PROJ_C" "$CASE_C" 6 2

inc
if ! grep -q 'EVENT: agent-finished issue=911 outcome=pr-open' "$CASE_C/queue.log"; then
  pass_msg "C1: no false-positive reap when 911 is not at pr-open"
else
  fail_msg "C1: predicate reaped 911 despite no pr-open label (false positive)"
  sed 's/^/    /' "$CASE_C/queue.log" >&2
fi
inc
if [ ! -f "$CASE_C/killed-911" ]; then
  pass_msg "C2: runner did NOT kill 911's window when pr-open absent"
else
  fail_msg "C2: runner force-closed 911 despite no pr-open label (false positive)"
fi

# ================= Case D: merged supersedes pr-open =================
echo ""
echo "Case D: merged label supersedes pr-open -> executor reap path suppressed"
CASE_D="$ROOT/caseD"; mkdir -p "$CASE_D"
PROJ_D="$CASE_D/proj"
setup_proj "$PROJ_D"
STUB_D=$(make_common_stubs "$PROJ_D" "$CASE_D")
# gh stub: 911 labels return `merged,pr-open`; 912 empty. The executor
# predicate's merged arm must short-circuit (return 1) so it does NOT record a
# bare outcome=pr-open; the existing is_agent_running / check_issue_outcome
# branches own the merged case.
cat > "$STUB_D/gh" <<'EOF'
#!/bin/bash
ARGS="$*"
case "$1 $2" in
  "issue view")
    issue="$3"
    if [[ "$ARGS" == *labels* ]]; then
      if [ "$issue" = "911" ]; then echo "merged,pr-open"; else echo ""; fi
    fi
    ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_D/gh"
run_case "$PROJ_D" "$CASE_D" 6 2

inc
if ! grep -q 'EVENT: agent-finished issue=911 outcome=pr-open' "$CASE_D/queue.log"; then
  pass_msg "D1: merged arm suppresses the executor reap path (no bare outcome=pr-open)"
else
  fail_msg "D1: executor reap fired despite merged label (should be owned by the existing branches)"
  sed 's/^/    /' "$CASE_D/queue.log" >&2
fi
inc
if [ ! -f "$CASE_D/killed-911" ]; then
  pass_msg "D2: runner did NOT kill 911's window when merged supersedes pr-open"
else
  fail_msg "D2: runner force-closed 911 via the executor path despite merged label"
fi

# ========= Case E: eval-mode queue does NOT reap on pr-open (#666) =========
echo ""
echo "Case E: --skill evaluate-issue-pr queue does NOT reap an evaluator at its pre-existing pr-open"
CASE_E="$ROOT/caseE"; mkdir -p "$CASE_E"
PROJ_E="$CASE_E/proj"
setup_proj "$PROJ_E"
STUB_E=$(make_common_stubs "$PROJ_E" "$CASE_E")
# gh stub identical to Case A (911 always pr-open, no manual-merge; pr view / pr
# list empty so evaluator_finished_terminal cannot fire). For an eval-mode queue,
# `pr-open` is the evaluator's INPUT state, not its finish line, so the executor
# reap branch must be gated off — 911 must be preserved.
cat > "$STUB_E/gh" <<'EOF'
#!/bin/bash
ARGS="$*"
case "$1 $2" in
  "issue view")
    issue="$3"
    if [[ "$ARGS" == *labels* ]]; then
      if [ "$issue" = "911" ]; then echo "pr-open"; else echo ""; fi
    fi
    ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_E/gh"
# Mirror Case A's generous timeout (30s) so the grace=2 reap WOULD fire absent
# the mode gate — that is what makes E1/E2 a real RED: without the gate the
# evaluator is wrongly reaped; with it, 911 is preserved.
run_case "$PROJ_E" "$CASE_E" 30 2 "--skill evaluate-issue-pr"

inc
if ! grep -q 'EVENT: agent-finished issue=911 outcome=pr-open' "$CASE_E/queue.log"; then
  pass_msg "E1: eval-mode queue does NOT reap a still-running evaluator at pr-open"
else
  fail_msg "E1: executor reap fired for an --skill evaluate-issue-pr queue (pr-open is the eval INPUT state)"
  sed 's/^/    /' "$CASE_E/queue.log" >&2
fi
inc
if [ ! -f "$CASE_E/killed-911" ]; then
  pass_msg "E2: eval-mode queue did NOT force-close 911's window at pr-open"
else
  fail_msg "E2: runner force-closed an evaluator's window on its pre-existing pr-open"
fi

# ============ Case F: process-group kill on reap (issue #666) ============
echo ""
echo "Case F: reap SIGTERM+SIGKILLs the worker process group, not just the window"
CASE_F="$ROOT/caseF"; mkdir -p "$CASE_F"
PROJ_F="$CASE_F/proj"
setup_proj "$PROJ_F"
STUB_F=$(make_common_stubs "$PROJ_F" "$CASE_F")
# Reuse Case A's transition-modeling gh stub (911 = `in-progress` for poll 1's
# two label queries, `pr-open` thereafter, no manual-merge, no Evaluation comment)
# so the #694 witness is set before the executor reap path fires. See Case A's
# stub comment for why n<2 == poll 1. Default skill (no --skill), grace=2 so the
# reap fires within the timeout.
cat > "$STUB_F/gh" <<EOF
#!/bin/bash
ARGS="\$*"
CNT_FILE="$CASE_F/poll-count-911"
case "\$1 \$2" in
  "issue view")
    issue="\$3"
    if [[ "\$ARGS" == *labels* ]]; then
      if [ "\$issue" = "911" ]; then
        n=\$(cat "\$CNT_FILE" 2>/dev/null || echo 0); echo \$((n+1)) > "\$CNT_FILE"
        if [ "\$n" -lt 2 ]; then echo "in-progress"; else echo "pr-open"; fi
      else echo ""; fi
    fi
    ;;
  "pr list") echo "null" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_F/gh"
run_case "$PROJ_F" "$CASE_F" 30 2

inc
if grep -q -- '-TERM -88811' "$CASE_F/kill-log" 2>/dev/null \
   && grep -q -- '-KILL -88811' "$CASE_F/kill-log" 2>/dev/null; then
  pass_msg "F1: reap SIGTERM+SIGKILLs the worker process group 88811"
else
  fail_msg "F1: expected kill -TERM -88811 then kill -KILL -88811 in kill-log"
  sed 's/^/    /' "$CASE_F/kill-log" >&2 2>/dev/null || true
fi
inc
if [ -f "$CASE_F/killed-911" ]; then
  pass_msg "F2: reap still force-closes 911's tmux window"
else
  fail_msg "F2: expected tmux kill-window for issue-911"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
