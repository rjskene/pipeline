#!/bin/bash
set -uo pipefail

# Tests that scripts/run-queue.sh treats a finished-evaluator worker as
# terminal — killing its tmux window and freeing the queue slot — when the
# evaluator has posted its verdict but the spawned `claude -p` child has not
# exited (the manual-merge / block-* wedge described in issue #489).
#
# Strategy: drive the FULL poll loop (non-dry-run) with a two-issue queue
# (911 + 912). Issue 912 finishes on the first poll (its window never appears
# in list-windows) so it exercises the existing is_agent_running==false branch.
# Issue 911 is the wedged evaluator: its tmux window stays present and its CPU
# stays healthy, so ONLY the new evaluator_finished_terminal() predicate can
# free its slot. Each case runs in its own scratch dir to prevent stub-state
# (label counters, kill markers) from leaking between cases.
#
# Three sub-cases:
#   A — `manual-merge` label arm (production wedge after Task 2.5 lands). The
#       label flips to manual-merge on the predicate's 2nd poll; the runner must
#       kill 911 and emit outcome=approved-manual-merge.
#   B — `Auto-merge skipped:` PR-comment arm (un-pre-labelled wedge, #459 shape).
#       Label never carries manual-merge; the predicate's comment arm fires from
#       the linked PR's last comment + Approved verdict.
#   C — fail-closed when no linked PR exists (executor crashed pre-PR). The
#       predicate MUST return non-terminal so the worker is NOT killed.
#
# Expected on first run (RED, before the predicate is wired): A1-A3, B1-B3 fail
# (911 never freed, runner reaped by `timeout`); C1, C2 pass coincidentally and
# stand as regression guards once the predicate exists.

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
mkdir -p "/tmp/wt-911-eval" "/tmp/wt-912-bar"
trap 'rm -rf "$ROOT" "/tmp/wt-911-eval" "/tmp/wt-912-bar"' EXIT

# Build a project tree with run-queue.sh + its sourced deps and a minimal config.
setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs"
  cp "$SCRIPT_UNDER_TEST" "$proj/.claude/scripts/run-queue.sh"
  cp "$REPO_ROOT/scripts/_logging.sh" "$proj/.claude/scripts/_logging.sh"
  cp "$REPO_ROOT/scripts/_resolve-container-var.sh" "$proj/.claude/scripts/_resolve-container-var.sh"
  cp "$REPO_ROOT/scripts/queue-status.sh" "$proj/.claude/scripts/queue-status.sh"
  cp "$REPO_ROOT/scripts/eval-classifier-invoke.sh" "$proj/.claude/scripts/eval-classifier-invoke.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh" "$proj/.claude/scripts/queue-status.sh" \
    "$proj/.claude/scripts/eval-classifier-invoke.sh"
  cat > "$proj/.claude/scripts/spawn-claude.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$proj/.claude/scripts/spawn-claude.sh"
  # PIPELINE_EVAL_CLASSIFIER="" short-circuits route_issue() to mode=bare with
  # NO gh round-trip, so the only gh traffic in the loop is the new predicate.
  cat > "$proj/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=""
PIPELINE_EVAL_CONTAINERS=""
EOF
}

# tmux + ps + git stubs shared by all three cases. $1=proj, $2=case scratch dir
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
  # never flags it. No other pids needed.
  cat > "$stub_dir/ps" <<'EOF'
#!/bin/bash
mode=""
for arg in "$@"; do
  case "$arg" in
    -eo) mode="eo" ;;
  esac
done
if [ "$mode" = "eo" ]; then
  echo "99911 1 50.0"
else
  echo "0.0"
fi
EOF
  chmod +x "$stub_dir/ps"

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
# $3=timeout seconds. EVENT lines go to stdout unconditionally (logging-off
# path), so we grep the captured stdout — no queue-*.log file needed.
run_case() {
  local proj="$1"
  local case_dir="$2"
  local tmo="$3"
  (
    cd "$proj"
    PATH="$proj/stub:$PATH" \
      TMUX="fake" \
      STUB_WORKTREES="911:eval 912:bar" \
      POLL_SECONDS=1 \
      STATUS_INTERVAL=999 \
      PIPELINE_PROJECT_ROOT="$proj" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      timeout "$tmo" bash .claude/scripts/run-queue.sh 911 912
  ) > "$case_dir/queue.log" 2>&1 || true
}

# ============================ Case A: label arm ============================
echo "Case A: manual-merge label arm frees the wedged evaluator slot"
CASE_A="$ROOT/caseA"; mkdir -p "$CASE_A"
PROJ_A="$CASE_A/proj"
setup_proj "$PROJ_A"
STUB_A=$(make_common_stubs "$PROJ_A" "$CASE_A")
# gh stub: 911's labels start at `pr-open` (predicate poll 1 misses), then flip
# to `manual-merge,pr-open` from the 2nd labels query onward (Task 2.5 applied
# the label). The PR-comment arm returns empty so only the label arm can fire.
cat > "$STUB_A/gh" <<EOF
#!/bin/bash
ARGS="\$*"
LABEL_COUNTER="$CASE_A/label-counter-911"
case "\$1 \$2" in
  "issue view")
    issue="\$3"
    if [[ "\$ARGS" == *labels* ]]; then
      if [ "\$issue" = "911" ]; then
        n=\$(cat "\$LABEL_COUNTER" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$LABEL_COUNTER"
        if [ "\$n" -ge 2 ]; then echo "manual-merge,pr-open"; else echo "pr-open"; fi
      else
        echo ""
      fi
    fi
    ;;
  "pr list") echo "1911" ;;
  "pr view") echo "" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_A/gh"
run_case "$PROJ_A" "$CASE_A" 30

inc
if grep -q 'EVENT: agent-finished issue=911 outcome=approved-manual-merge' "$CASE_A/queue.log"; then
  pass_msg "A1: runner emits agent-finished outcome=approved-manual-merge for 911"
else
  fail_msg "A1: expected agent-finished outcome=approved-manual-merge for 911"
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

# ====================== Case B: Auto-merge skipped arm ======================
echo ""
echo "Case B: Auto-merge skipped PR-comment arm frees the un-pre-labelled wedge"
CASE_B="$ROOT/caseB"; mkdir -p "$CASE_B"
PROJ_B="$CASE_B/proj"
setup_proj "$PROJ_B"
STUB_B=$(make_common_stubs "$PROJ_B" "$CASE_B")
# gh stub: label never carries manual-merge; the linked PR (1911) last comment
# is the `Auto-merge skipped:` block-* shape and the latest `## Evaluation`
# comment carries an Approved verdict — so the comment arm fires.
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
  "pr list") echo "1911" ;;
  "pr view")
    if [[ "$ARGS" == *'comments[-1]'* ]]; then
      echo 'Auto-merge skipped: block-verdict. Run `gh pr merge` manually.'
    else
      printf '## Evaluation\n\n**Verdict:** Approved\n'
    fi
    ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_B/gh"
run_case "$PROJ_B" "$CASE_B" 30

inc
if grep -q 'EVENT: agent-finished issue=911 outcome=approved-manual-merge' "$CASE_B/queue.log"; then
  pass_msg "B1: runner emits agent-finished outcome=approved-manual-merge for 911"
else
  fail_msg "B1: expected agent-finished outcome=approved-manual-merge for 911"
  sed 's/^/    /' "$CASE_B/queue.log" >&2
fi
inc
if [ -f "$CASE_B/killed-911" ]; then
  pass_msg "B2: runner force-closed 911's tmux window"
else
  fail_msg "B2: expected tmux kill-window for issue-911 (no killed-911 marker)"
fi
inc
if grep -q 'EVENT: queue-complete total=2' "$CASE_B/queue.log"; then
  pass_msg "B3: queue reaches queue-complete without waiting out the wedge"
else
  fail_msg "B3: expected EVENT: queue-complete total=2"
fi

# ===================== Case C: fail-closed when no PR =====================
echo ""
echo "Case C: no linked PR -> predicate fail-closed, worker NOT killed"
CASE_C="$ROOT/caseC"; mkdir -p "$CASE_C"
PROJ_C="$CASE_C/proj"
setup_proj "$PROJ_C"
STUB_C=$(make_common_stubs "$PROJ_C" "$CASE_C")
# gh stub: 911 carries `pr-open` only (no manual-merge); the linked-PR lookup
# returns the literal string `null` — exactly what `gh pr list --json number
# --jq '.[0].number'` prints for an empty result set (NOT an empty string).
# Both predicate arms must fail closed, so 911 stays alive. The `pr view` branch
# touches a marker so we can assert the predicate bails at the no-PR lookup
# guard WITHOUT issuing a malformed `gh pr view null` call. A short timeout
# bounds the runtime: several polls confirm no false-positive kill; the
# deterministic lookup means more polls add nothing.
cat > "$STUB_C/gh" <<EOF
#!/bin/bash
PR_VIEW_MARKER="$CASE_C/pr-view-called"
ARGS="\$*"
case "\$1 \$2" in
  "issue view")
    issue="\$3"
    if [[ "\$ARGS" == *labels* ]]; then
      if [ "\$issue" = "911" ]; then echo "pr-open"; else echo ""; fi
    fi
    ;;
  "pr list") echo "null" ;;
  "pr view") : > "\$PR_VIEW_MARKER"; echo "" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB_C/gh"
run_case "$PROJ_C" "$CASE_C" 10

inc
if ! grep -q 'EVENT: agent-finished issue=911 outcome=approved-manual-merge' "$CASE_C/queue.log"; then
  pass_msg "C1: no false-positive agent-finished for 911 when no PR exists"
else
  fail_msg "C1: predicate fired terminal for 911 despite no linked PR (false positive)"
  sed 's/^/    /' "$CASE_C/queue.log" >&2
fi
inc
if [ ! -f "$CASE_C/killed-911" ]; then
  pass_msg "C2: runner did NOT kill 911's window when no PR exists"
else
  fail_msg "C2: runner force-closed 911 despite no linked PR (false positive)"
fi
inc
if [ ! -f "$CASE_C/pr-view-called" ]; then
  pass_msg "C3: predicate bails at the null PR-lookup guard (no gh pr view null call)"
else
  fail_msg "C3: predicate issued a malformed 'gh pr view null' instead of bailing on the null lookup"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
