#!/bin/bash
set -uo pipefail
#
# test-inline-eval-dispatch-contract.sh — verifies the inline-dispatch EVENT
# contract from scripts/run-queue.sh launch_agent() (issue #517).
#
# When the classifier matches a browser-eval surface AND PIPELINE_EVAL_ISOLATION
# is not "container", run-queue.sh emits a single
#   EVENT: dispatch-inline issue=<N> port=<P> target_dir=<DIR> worktree=<PATH> pr=<PR>
# line on stdout (also written to the queue log when logging is enabled), sets
# RESULTS[<issue>]=dispatched-inline, and short-circuits — spawn-claude.sh is
# NOT invoked for that issue. Bare issues continue to flow through spawn-claude
# untouched.
#
# Strategy mirrors test-eval-classifier-e2e-dryrun.sh: a real run-queue.sh +
# real eval-classifier-invoke.sh, with spawn-claude.sh stubbed to log argv.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_QUEUE_SRC="$ROOT/scripts/run-queue.sh"
HELPER_SRC="$ROOT/scripts/eval-classifier-invoke.sh"
PORT_BROKER_SRC="$ROOT/scripts/visual-proof-port-broker.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$RUN_QUEUE_SRC" "$HELPER_SRC" "$PORT_BROKER_SRC"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR" /tmp/wt-510-a /tmp/wt-511-b 2>/dev/null' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/scripts" "$PROJ/.claude/logs" \
         "$PROJ/plugin-root/scripts"
cp "$RUN_QUEUE_SRC"     "$PROJ/plugin-root/scripts/run-queue.sh"
cp "$ROOT/scripts/_logging.sh" "$PROJ/plugin-root/scripts/_logging.sh"
cp "$ROOT/scripts/_resolve-container-var.sh" "$PROJ/plugin-root/scripts/_resolve-container-var.sh"
cp "$HELPER_SRC"        "$PROJ/plugin-root/scripts/eval-classifier-invoke.sh"
cp "$PORT_BROKER_SRC"   "$PROJ/plugin-root/scripts/visual-proof-port-broker.sh"
chmod +x "$PROJ/plugin-root/scripts/run-queue.sh" \
         "$PROJ/plugin-root/scripts/eval-classifier-invoke.sh" \
         "$PROJ/plugin-root/scripts/visual-proof-port-broker.sh"

# Stub spawn-claude.sh: log argv to $SPAWN_LOG and exit 0.
cat > "$PROJ/plugin-root/scripts/spawn-claude.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SPAWN_LOG"
exit 0
EOF
chmod +x "$PROJ/plugin-root/scripts/spawn-claude.sh"

# Classifier: issues in CLASSIFIER_WEB_ISSUES get --container-mode=mock-web-eval.
cat > "$PROJ/.claude/scripts/classifier.sh" <<'EOF'
#!/bin/bash
ISSUE="$1"
for wi in ${CLASSIFIER_WEB_ISSUES:-}; do
  if [ "$ISSUE" = "$wi" ]; then
    echo "--container-mode=mock-web-eval"
    exit 0
  fi
done
exit 0
EOF
chmod +x "$PROJ/.claude/scripts/classifier.sh"

cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="mock-web-eval"
PIPELINE_VISUAL_PROOF_TARGET_DIR=".eval-screenshots"
EOF

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
# resolve_issue_pr uses `gh pr list --search "linked:<issue>"` and reads .[0].number
# Map issue -> PR number via STUB_PR_FOR_<issue> env, default empty.
for a in "$@"; do :; done
# Find the issue number from `linked:<N>` token in argv.
for tok in "$@"; do
  case "$tok" in
    linked:*) issue="${tok#linked:}" ;;
  esac
done
issue="${issue:-}"
varname="STUB_PR_FOR_${issue}"
val="${!varname:-}"
if [ -n "$val" ]; then
  echo "$val"
else
  echo ""
fi
EOF
cat > "$STUB_DIR/git" <<'EOF'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"
    slug="${entry##*:}"
    echo "worktree /tmp/wt-${issue}-${slug}"
    echo "HEAD abc"
    echo "branch refs/heads/feature/${slug}"
    echo ""
  done
fi
EOF
chmod +x "$STUB_DIR/tmux" "$STUB_DIR/gh" "$STUB_DIR/git"

SPAWN_LOG="$PROJ/spawn-invocations.log"
: > "$SPAWN_LOG"

# Create worktree dirs the runner expects.
mkdir -p /tmp/wt-510-a /tmp/wt-511-b

# ---- Test: inline dispatch emits EVENT line with all five fields ----
echo "Test: classifier match + ISOLATION unset -> EVENT: dispatch-inline"
inc
OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  TMUX="fake" \
  SPAWN_LOG="$SPAWN_LOG" \
  PIPELINE_QUEUE_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=false \
  STUB_WORKTREES="510:a 511:b" \
  CLASSIFIER_WEB_ISSUES="510" \
  STUB_PR_FOR_510="9001" \
  CLAUDE_PLUGIN_ROOT="$PROJ/plugin-root" \
  bash plugin-root/scripts/run-queue.sh 510 511 2>&1)

# 510 is browser-eval, ISOLATION unset -> inline. 511 is bare -> spawn-claude.
EVENT_LINE=$(echo "$OUT" | grep '^EVENT: dispatch-inline' | head -1)

if [ -z "$EVENT_LINE" ]; then
  fail_msg "expected EVENT: dispatch-inline line in stdout"
  echo "$OUT" | sed 's/^/    /'
elif ! echo "$EVENT_LINE" | grep -q 'issue=510'; then
  fail_msg "EVENT line missing issue=510 field"
  echo "    $EVENT_LINE"
elif ! echo "$EVENT_LINE" | grep -qE 'port=[0-9]+'; then
  fail_msg "EVENT line missing port=<n> field"
  echo "    $EVENT_LINE"
elif ! echo "$EVENT_LINE" | grep -q 'target_dir='; then
  fail_msg "EVENT line missing target_dir= field"
  echo "    $EVENT_LINE"
elif ! echo "$EVENT_LINE" | grep -q 'worktree=/tmp/wt-510-a'; then
  fail_msg "EVENT line missing worktree=/tmp/wt-510-a"
  echo "    $EVENT_LINE"
elif ! echo "$EVENT_LINE" | grep -q 'pr=9001'; then
  fail_msg "EVENT line missing pr=9001 field"
  echo "    $EVENT_LINE"
else
  pass_msg "EVENT: dispatch-inline line carries issue/port/target_dir/worktree/pr"
fi

# Inline issue must NOT invoke spawn-claude.
inc
echo "Test: inline issue does NOT invoke spawn-claude"
if grep -E "(^| )510( |$)" "$SPAWN_LOG" >/dev/null 2>&1; then
  fail_msg "spawn-claude.sh invoked for inline issue 510"
  cat "$SPAWN_LOG" | sed 's/^/    /'
else
  pass_msg "spawn-claude.sh NOT invoked for inline issue 510"
fi

# Bare issue 511 should still call spawn-claude.
inc
echo "Test: bare issue still flows through spawn-claude"
if grep -E "(^| )511( |$)" "$SPAWN_LOG" >/dev/null 2>&1; then
  pass_msg "spawn-claude.sh invoked for bare issue 511"
else
  fail_msg "spawn-claude.sh NOT invoked for bare issue 511 (regression)"
  cat "$SPAWN_LOG" | sed 's/^/    /'
fi

# ---- Test: multi-issue inline slate dispatches ALL issues in a single mode ----
# Regression guard for the must-fix raised by code review on #517: launch_agent
# bumped BUCKET_ACTIVE[$mode] on the inline dispatch path, but there is no
# decrementer for inline issues in the poll loop (decrement only happens for
# spawn-claude-tracked agents via ACTIVE[$issue]). With BUCKET_MAX defaulting to
# 1, only the first inline issue per mode ever got dispatched; subsequent
# issues stayed parked in BUCKET_QUEUE forever. Inline dispatches are
# instantaneous EVENT-line emissions with no async subprocess to gate on, so
# they should NOT count against the bucket cap.
echo "Test: multi-issue inline slate dispatches BOTH issues (no BUCKET_ACTIVE block)"
inc
: > "$SPAWN_LOG"
mkdir -p /tmp/wt-510-a /tmp/wt-512-c
OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  TMUX="fake" \
  SPAWN_LOG="$SPAWN_LOG" \
  PIPELINE_QUEUE_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=false \
  STUB_WORKTREES="510:a 512:c" \
  CLASSIFIER_WEB_ISSUES="510 512" \
  STUB_PR_FOR_510="9001" \
  STUB_PR_FOR_512="9002" \
  CLAUDE_PLUGIN_ROOT="$PROJ/plugin-root" \
  bash plugin-root/scripts/run-queue.sh 510 512 2>&1)

DISPATCH_COUNT=$(echo "$OUT" | grep -c '^EVENT: dispatch-inline')
if [ "$DISPATCH_COUNT" -eq 2 ]; then
  pass_msg "both inline issues dispatched (EVENT count=2)"
elif [ "$DISPATCH_COUNT" -eq 1 ]; then
  fail_msg "only 1 inline EVENT line — BUCKET_ACTIVE blocked 2nd dispatch"
  echo "$OUT" | sed 's/^/    /'
else
  fail_msg "unexpected EVENT: dispatch-inline count=$DISPATCH_COUNT"
  echo "$OUT" | sed 's/^/    /'
fi

# Both inline issues must appear in the EVENT lines.
inc
echo "Test: both inline issue numbers present in EVENT lines"
if echo "$OUT" | grep -q '^EVENT: dispatch-inline.* issue=510' && \
   echo "$OUT" | grep -q '^EVENT: dispatch-inline.* issue=512'; then
  pass_msg "EVENT lines cover issue=510 AND issue=512"
else
  fail_msg "EVENT lines missing one or both issues"
  echo "$OUT" | grep '^EVENT:' | sed 's/^/    /'
fi

rm -rf /tmp/wt-512-c 2>/dev/null || true

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
