#!/bin/bash
set -uo pipefail

export PIPELINE_LOGS_ENABLED=true

# End-to-end dry-run wiring test for the classifier + container-mode
# dispatch path (issue #218). Composes the real helper + the real
# run-queue.sh template + the real spawn-claude.sh template into a single
# temp project tree, stubs external binaries (gh, docker, tmux, git), and
# asserts that the contract holds across the three units.
#
# This is a glue-only regression net — it does NOT change production code.
# If it fails, fix the underlying task before moving on.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_QUEUE_SRC="$ROOT/scripts/run-queue.sh"
SPAWN_SRC="$ROOT/scripts/spawn-claude.sh"
HELPER_SRC="$ROOT/scripts/eval-classifier-invoke.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$RUN_QUEUE_SRC" "$SPAWN_SRC" "$HELPER_SRC"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

setup_proj() {
  local proj="$1" classifier_path="$2"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs" "$proj/scripts" "$proj/plugin-root/scripts"
  # Stage plugin-shipped artifacts at $proj/plugin-root/scripts/ so
  # ${CLAUDE_PLUGIN_ROOT}/scripts/ resolution (run-queue.sh's _logging.sh
  # source, eval-classifier-invoke.sh invocation, and spawn-claude.sh
  # dispatch) all find their files under the same plugin-root prefix.
  # CLAUDE_PLUGIN_ROOT is set by run_queue_dryrun below.
  cp "$RUN_QUEUE_SRC" "$proj/plugin-root/scripts/run-queue.sh"
  cp "$ROOT/scripts/_logging.sh" "$proj/plugin-root/scripts/_logging.sh"
  # run-queue.sh sources _resolve-container-var.sh from SCRIPT_DIR (#336);
  # colocate it next to run-queue.sh in the plugin-root fixture.
  cp "$ROOT/scripts/_resolve-container-var.sh" "$proj/plugin-root/scripts/_resolve-container-var.sh"
  # Stub spawn-claude.sh: log argv and exit 0.
  cat > "$proj/plugin-root/scripts/spawn-claude.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$SPAWN_LOG"
exit 0
EOF
  chmod +x "$proj/plugin-root/scripts/run-queue.sh" "$proj/plugin-root/scripts/spawn-claude.sh"
  cp "$HELPER_SRC" "$proj/plugin-root/scripts/eval-classifier-invoke.sh"
  chmod +x "$proj/plugin-root/scripts/eval-classifier-invoke.sh"
  if [ -n "$classifier_path" ]; then
    # Write a real classifier script that emits --container-mode=web-eval for
    # issues in CLASSIFIER_WEB_ISSUES (space-separated env).
    cat > "$classifier_path" <<'EOF'
#!/bin/bash
ISSUE="$1"
for wi in ${CLASSIFIER_WEB_ISSUES:-}; do
  if [ "$ISSUE" = "$wi" ]; then
    echo "--container-mode=web-eval"
    [ -n "${CLASSIFIER_EXTRA_TOKENS:-}" ] && for tok in $CLASSIFIER_EXTRA_TOKENS; do echo "$tok"; done
    exit 0
  fi
done
exit 0
EOF
    chmod +x "$classifier_path"
  fi
}

make_stubs() {
  local stub_dir="$1/stub"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$stub_dir/gh"  <<'EOF'
#!/bin/bash
echo ""
EOF
  cat > "$stub_dir/git" <<'EOF'
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
  cat > "$stub_dir/docker" <<'EOF'
#!/bin/bash
echo "STUB_DOCKER $*"
EOF
  chmod +x "$stub_dir/tmux" "$stub_dir/gh" "$stub_dir/git" "$stub_dir/docker"
  echo "$stub_dir"
}

run_queue_dryrun() {
  local proj="$1" stub_dir="$2"; shift 2
  local spawn_log="$proj/spawn-invocations.log"
  : > "$spawn_log"
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"
    slug="${entry##*:}"
    mkdir -p "/tmp/wt-${issue}-${slug}"
  done
  (
    cd "$proj"
    PATH="$stub_dir:$PATH" \
      TMUX="fake" \
      SPAWN_LOG="$spawn_log" \
      PIPELINE_QUEUE_DRY_RUN=1 \
      CLAUDE_PLUGIN_ROOT="$proj/plugin-root" \
      bash plugin-root/scripts/run-queue.sh "$@" 2>&1
  )
}

# -------------------------------------------------------------------------
# Test 1: classifier set + mixed slate -> correct BUCKET: + spawn argv
# -------------------------------------------------------------------------
echo "Test 1: mixed slate produces correct bucket assignments + spawn flags"
inc
PROJ="$WORKDIR/p1"
setup_proj "$PROJ" "$PROJ/.claude/scripts/classifier.sh"
STUB_DIR=$(make_stubs "$PROJ")
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
EOF
OUT=$(STUB_WORKTREES="200:a 201:b 202:c 203:d" \
      CLASSIFIER_WEB_ISSUES="200 202" \
      run_queue_dryrun "$PROJ" "$STUB_DIR" 200 201 202 203)
SPAWN_LOG="$PROJ/spawn-invocations.log"

ok=1
echo "$OUT" | grep -qE '^BUCKET: mode=web-eval issues=.*200.*202.* max=1$' \
  || echo "$OUT" | grep -qE '^BUCKET: mode=web-eval issues=.*202.*200.* max=1$' \
  || { fail_msg "missing web-eval bucket line containing 200+202"; ok=0; }
[ "$ok" = "1" ] && (echo "$OUT" | grep -qE '^BUCKET: mode=bare issues=' || { fail_msg "missing bare bucket line"; ok=0; })
# Cap=1 means only the first web-eval issue launches in the initial fill.
# Whichever launched MUST carry --container-mode=web-eval.
if [ "$ok" = "1" ]; then
  web_invocations=$(grep -- "--container-mode=web-eval" "$SPAWN_LOG" | wc -l)
  if [ "$web_invocations" -lt 1 ]; then
    fail_msg "expected at least one --container-mode=web-eval spawn, got $web_invocations"
    cat "$SPAWN_LOG" | sed 's/^/    /'
    ok=0
  fi
fi
# Bare issues that DID launch must not carry --container-mode.
if [ "$ok" = "1" ]; then
  for bi in 201 203; do
    if grep -E "(^| )$bi( |$)" "$SPAWN_LOG" | grep -q -- "--container-mode"; then
      fail_msg "bare issue $bi unexpectedly has --container-mode flag"
      ok=0
      break
    fi
  done
fi
[ "$ok" = "1" ] && pass_msg "two buckets + per-issue --container-mode flags route correctly"

# -------------------------------------------------------------------------
# Test 2: --classifier-passthrough threaded end-to-end through spawn argv
# -------------------------------------------------------------------------
echo "Test 2: classifier passthrough tokens threaded end-to-end"
inc
PROJ="$WORKDIR/p2"
setup_proj "$PROJ" "$PROJ/.claude/scripts/classifier.sh"
STUB_DIR=$(make_stubs "$PROJ")
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
EOF
OUT=$(STUB_WORKTREES="300:a 301:b" \
      CLASSIFIER_WEB_ISSUES="300" \
      CLASSIFIER_EXTRA_TOKENS="--foo=bar" \
      run_queue_dryrun "$PROJ" "$STUB_DIR" 300 301)
SPAWN_LOG="$PROJ/spawn-invocations.log"
INVOCATION_300=$(grep '300' "$SPAWN_LOG" | head -1)
if echo "$INVOCATION_300" | grep -q -- "--container-mode=web-eval" \
   && echo "$INVOCATION_300" | grep -q -- "--classifier-passthrough=--foo=bar"; then
  pass_msg "issue 300 spawn carries --container-mode and --classifier-passthrough"
else
  fail_msg "issue 300 spawn missing expected flags: '$INVOCATION_300'"
fi

# -------------------------------------------------------------------------
# Test 3: PIPELINE_EVAL_CLASSIFIER unset -> identical to today's behavior
# -------------------------------------------------------------------------
echo "Test 3: classifier unset -> single bare bucket, zero --container-mode flags"
inc
PROJ="$WORKDIR/p3"
setup_proj "$PROJ" ""
STUB_DIR=$(make_stubs "$PROJ")
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=""
PIPELINE_EVAL_CONTAINERS=""
EOF
OUT=$(STUB_WORKTREES="400:a 401:b 402:c" \
      run_queue_dryrun "$PROJ" "$STUB_DIR" 400 401 402)
SPAWN_LOG="$PROJ/spawn-invocations.log"
ok=1
if grep -q -- "--container-mode" "$SPAWN_LOG"; then
  fail_msg "classifier unset but spawn log contains --container-mode"
  cat "$SPAWN_LOG" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT" | grep -qE '^BUCKET: mode=bare issues=.*400.*401.*402'; then
  fail_msg "missing single bare bucket containing all issues"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "unset classifier preserves today's single-bucket behavior"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
