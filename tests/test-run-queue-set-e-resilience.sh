#!/bin/bash
set -uo pipefail

# Regression guard for issue #630: a TRANSIENT non-zero from a poll-loop
# external command must NOT silently kill scripts/run-queue.sh. The trippable
# site is the BARE top-level command-sub at run-queue.sh L664 inside the
# stall-latch branch:  pid=$(tmux list-panes ... | head -1).  Under
# `set -euo pipefail`, when `tmux list-panes` exits non-zero the pipe's rc is
# non-zero (pipefail) and the bare assignment trips errexit, aborting the whole
# runner with no diagnostic, so `EVENT: queue-complete` never prints (pre-fix
# RED). After the fix, errexit is scoped OFF for the poll-loop region, the blip
# degrades that poll, the loop runs to completion, and an EXIT-trap emits
# `EVENT: runner-aborted ...` ONLY on a genuinely-abnormal exit.
#
# NOTE on injection-site choice: the OTHER list-panes call at L392 (inside
# get_agent_cpu_pct) is NOT trippable from the loop — it is reached via
# `_s=$(get_agent_cpu_pct ...)` at L647, an OUTER command-sub assignment, and
# bash's errexit exemption for `var=$(cmdsub)` masks the inner failure. Only
# the BARE L664 assignment trips. The stub therefore (a) makes list-panes
# ALWAYS fail (the masked L392 read tolerates it, returning 0.0 -> idle), and
# (b) drives ps to 0.0% so the stall threshold latches and L664 runs.
#
# Harness mirrors tests/test-run-queue-stall-detection.sh: full poll loop,
# two active issues, PATH-shadowed stubs, a counter-file list-windows stub
# that drops the window after N polls so the loop terminates post-fix.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/run-queue.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR" /tmp/wt-941-foo /tmp/wt-942-bar' EXIT

setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs"
  cp "$SCRIPT_UNDER_TEST" "$proj/.claude/scripts/run-queue.sh"
  cp "$REPO_ROOT/scripts/_logging.sh" "$proj/.claude/scripts/_logging.sh"
  cp "$REPO_ROOT/scripts/queue-status.sh" "$proj/.claude/scripts/queue-status.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh" "$proj/.claude/scripts/queue-status.sh"
  cat > "$proj/.claude/scripts/spawn-claude.sh" <<'SPAWN'
#!/bin/bash
exit 0
SPAWN
  chmod +x "$proj/.claude/scripts/spawn-claude.sh"
  cat > "$proj/pipeline.config" <<CFG
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
CFG
}

# Stubs. gh: always succeeds (empty output) — NOT the injection site. tmux:
# list-windows returns issue-941 for the first 12 calls (long enough to latch
# the stall), then drops it so the loop ends post-fix; list-panes ALWAYS
# exits non-zero (the tmux race) — the masked L392 read tolerates it, and the
# BARE L664 stall-path assignment trips errexit pre-fix. ps reports 0.0% so
# the stall threshold (=2) latches and L664 is reached. git serves worktree
# list from STUB_WORKTREES.
make_stubs() {
  local proj="$1"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"
  local win_counter="$WORKDIR/win-counter-$(basename "$proj")"
  echo 0 > "$win_counter"

  cat > "$stub_dir/gh" <<'GH'
#!/bin/bash
echo ""
GH
  chmod +x "$stub_dir/gh"

  cat > "$stub_dir/tmux" <<TMUX
#!/bin/bash
WIN_COUNTER="$win_counter"
case "\$1" in
  list-windows)
    n=\$(cat "\$WIN_COUNTER" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$WIN_COUNTER"
    if [ "\$n" -le 12 ]; then echo "issue-941"; fi
    ;;
  list-panes) exit 1 ;;
  *) exit 0 ;;
esac
TMUX
  chmod +x "$stub_dir/tmux"

  cat > "$stub_dir/ps" <<'PS'
#!/bin/bash
mode=""
for arg in "$@"; do case "$arg" in -eo) mode="eo" ;; esac; done
if [ "$mode" = "eo" ]; then
  echo "94100 1 0.0"
  echo "94200 1 0.0"
else
  echo "0.0"
fi
PS
  chmod +x "$stub_dir/ps"

  cat > "$stub_dir/git" <<'GIT'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"; slug="${entry##*:}"
    echo "worktree /tmp/wt-${issue}-${slug}"
    echo "HEAD abc123"
    echo "branch refs/heads/feature/${slug}"
    echo ""
  done
fi
GIT
  chmod +x "$stub_dir/git"

  echo "$stub_dir"
}

run_loop() {
  local proj="$1" stub="$2" stdout="$3"
  mkdir -p /tmp/wt-941-foo /tmp/wt-942-bar
  (
    cd "$proj"
    PATH="$stub:$PATH" \
      TMUX="fake" \
      STUB_WORKTREES="941:foo 942:bar" \
      PIPELINE_LOGS_ENABLED=true \
      POLL_SECONDS=1 \
      STATUS_INTERVAL=10000 \
      PIPELINE_STALL_POLL_THRESHOLD=2 \
      PIPELINE_STALL_SAMPLES_PER_POLL=1 \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      bash .claude/scripts/run-queue.sh 941 942
  ) > "$stdout" 2>&1
}

# ---- Test 1: runner survives a transient tmux list-panes non-zero ----------
echo "Test 1: transient tmux list-panes non-zero on the stall path does NOT kill the runner"
inc
PROJ="$WORKDIR/p1"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
STDOUT="$WORKDIR/queue-stdout.log"
run_loop "$PROJ" "$STUB_DIR" "$STDOUT"

if grep -q 'EVENT: queue-complete total=2' "$STDOUT"; then
  pass_msg "runner reached queue-complete despite the transient tmux list-panes non-zero"
else
  fail_msg "runner died mid-loop (no 'EVENT: queue-complete total=2') — set -e killed it on the L664 list-panes blip"
  echo "--- stdout capture ---" >&2; sed 's/^/    /' "$STDOUT" >&2
fi

# ---- Test 2: no false runner-aborted diagnostic on the clean path ----------
echo ""
echo "Test 2: clean completion emits NO 'EVENT: runner-aborted' diagnostic"
inc
if grep -q 'EVENT: runner-aborted' "$STDOUT"; then
  fail_msg "false-positive 'EVENT: runner-aborted' on a run that completed normally"
  echo "--- stdout capture ---" >&2; sed 's/^/    /' "$STDOUT" >&2
else
  pass_msg "no runner-aborted diagnostic on the normal queue-complete path"
fi

# ---- Test 3: a genuine abnormal abort emits the runner-aborted diagnostic ---
#
# Force a deterministic abnormal exit that fires AFTER the trap is installed
# and while errexit is still on (the setup region, before the poll loop's
# `set +e`): run with TMUX UNSET so run-queue.sh's "must run inside tmux"
# guard hits its `exit 1` (L168-172). That guard is intentionally NOT
# RUNNER_DONE-silenced (unlike the empty-queue/queue-complete paths), so the
# EXIT trap must emit the diagnostic before the non-zero exit. NOTE: the abort
# must occur AFTER the trap-install point (right after the log() definition);
# the TMUX guard qualifies. Do NOT trigger via a pre-trap failure (e.g.
# deleting _logging.sh, whose `source` runs earlier) — the trap would not yet
# exist and the diagnostic would not fire.
echo ""
echo "Test 3: genuine abnormal exit emits 'EVENT: runner-aborted' with cmd= and rc="
inc
PROJ3="$WORKDIR/p3"
setup_proj "$PROJ3"
STUB_DIR3=$(make_stubs "$PROJ3")
STDOUT3="$WORKDIR/queue-stdout-abort.log"
(
  cd "$PROJ3"
  env -u TMUX PATH="$STUB_DIR3:$PATH" \
    STUB_WORKTREES="941:foo" \
    POLL_SECONDS=1 \
    STATUS_INTERVAL=10000 \
    CLAUDE_PLUGIN_ROOT="$PROJ3/.claude" \
    bash .claude/scripts/run-queue.sh 941 942
) > "$STDOUT3" 2>&1 || true

if grep -qE 'EVENT: runner-aborted cmd=.* rc=[0-9]+' "$STDOUT3"; then
  pass_msg "abnormal exit emitted runner-aborted with cmd= and rc= fields"
else
  fail_msg "abnormal exit produced no 'EVENT: runner-aborted cmd=... rc=...' diagnostic"
  echo "--- stdout capture ---" >&2; sed 's/^/    /' "$STDOUT3" >&2
fi

# ---- Test 4: static lint — errexit scoped off around the poll loop + trap ---
echo ""
echo "Test 4: run-queue.sh scopes errexit off around the poll loop and installs the trap"
inc
RQ="$REPO_ROOT/scripts/run-queue.sh"
lint_ok=1
grep -q 'set +e' "$RQ"            || { fail_msg "no 'set +e' (errexit not scoped off for the poll loop)"; lint_ok=0; }
grep -qE 'trap .* EXIT' "$RQ"     || { fail_msg "no EXIT trap installed for the abnormal-exit diagnostic"; lint_ok=0; }
grep -q 'runner-aborted' "$RQ"    || { fail_msg "no 'runner-aborted' diagnostic string in the script"; lint_ok=0; }
[ "$lint_ok" = "1" ] && pass_msg "errexit scoped off + EXIT trap + runner-aborted diagnostic all present"

# ---- Test 5: trap stays silent on the benign empty-queue exit 1 ------------
#
# Regression guard for the eval's false-fire nit: running with NO issue args
# hits the empty-queue usage `exit 1` (L162-165), which is AFTER the trap
# install. The RUNNER_DONE=1 set on that path must keep the trap silent so the
# orchestrator's Monitor is not fed a spurious abort event on an operator typo.
echo ""
echo "Test 5: empty-queue usage exit emits NO 'EVENT: runner-aborted'"
inc
PROJ5="$WORKDIR/p5"
setup_proj "$PROJ5"
STUB_DIR5=$(make_stubs "$PROJ5")
STDOUT5="$WORKDIR/queue-stdout-empty.log"
(
  cd "$PROJ5"
  PATH="$STUB_DIR5:$PATH" TMUX="fake" CLAUDE_PLUGIN_ROOT="$PROJ5/.claude" \
    bash .claude/scripts/run-queue.sh
) > "$STDOUT5" 2>&1 || true
if grep -q 'EVENT: runner-aborted' "$STDOUT5"; then
  fail_msg "false 'EVENT: runner-aborted' on the benign empty-queue exit 1"
  echo "--- stdout capture ---" >&2; sed 's/^/    /' "$STDOUT5" >&2
else
  pass_msg "no runner-aborted diagnostic on the benign empty-queue exit"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
