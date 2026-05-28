#!/bin/bash
set -uo pipefail

export PIPELINE_LOGS_ENABLED=true

# Tests for the always-inline run-queue dispatch contract (issue #514).
#
# Container isolation and the pre-spawn PIPELINE_EVAL_CLASSIFIER re-run
# were removed in #514; every issue now lands in the single `bare` bucket
# and no `--container-mode` token ever appears in the spawn argv.
#
# Uses PIPELINE_QUEUE_DRY_RUN=1 to short-circuit the poll loop after
# initial classification + first fill_slots. Stubs:
#   - gh:       returns canned labels/PR-list output
#   - tmux:     no-op; never matters in dry-run
#   - git:      returns canned worktree-list output so find_worktree resolves
#   - spawn-claude.sh: logs argv to $PROJ/spawn-invocations.log and exits 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/run-queue.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs"
  cp "$SCRIPT_UNDER_TEST" "$proj/.claude/scripts/run-queue.sh"
  cp "$SCRIPT_DIR/../scripts/_logging.sh" "$proj/.claude/scripts/_logging.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh"
  # Stub spawn-claude.sh: logs argv and exits 0
  cat > "$proj/.claude/scripts/spawn-claude.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SPAWN_LOG"
exit 0
EOF
  chmod +x "$proj/.claude/scripts/spawn-claude.sh"
}

# Stub binaries common to every test.
make_stubs() {
  local proj="$1"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"

  # tmux: no-op; pretend session always exists.
  cat > "$stub_dir/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  list-windows) exit 0 ;;
  has-session)  exit 0 ;;
  *)            exit 0 ;;
esac
EOF
  chmod +x "$stub_dir/tmux"

  # gh: returns mock labels / PR number list, and logs argv to GH_INVOCATIONS.
  cat > "$stub_dir/gh" <<'EOF'
#!/bin/bash
if [ -n "${GH_INVOCATIONS:-}" ]; then
  printf '%s\n' "$*" >> "$GH_INVOCATIONS"
fi
echo ""
EOF
  chmod +x "$stub_dir/gh"

  # git: only `git worktree list --porcelain` matters.
  cat > "$stub_dir/git" <<'EOF'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  # STUB_WORKTREES is a newline-separated list of "issue:slug" pairs.
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

run_dryrun() {
  # $@: extra args to run-queue.sh (issue numbers etc.)
  local proj="$1"; shift
  local stub_dir="$1"; shift
  local spawn_log="$proj/spawn-invocations.log"
  local gh_log="$proj/gh-invocations.log"
  : > "$spawn_log"; : > "$gh_log"
  # Materialize the stubbed worktree directories so `[ -d $wt_path ]` passes.
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"
    slug="${entry##*:}"
    mkdir -p "/tmp/wt-${issue}-${slug}"
  done
  (
    cd "$proj"
    PATH="$stub_dir:$PATH" \
      TMUX="fakesession" \
      SPAWN_LOG="$spawn_log" \
      GH_INVOCATIONS="$gh_log" \
      PIPELINE_QUEUE_DRY_RUN=1 \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      bash .claude/scripts/run-queue.sh "$@" 2>&1
  )
}

write_minimal_config() {
  local proj="$1"
  cat > "$proj/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
EOF
}

# -------------------------------------------------------------------------
# Test 1: multi-issue dispatch -> single bare bucket, no --container-mode
# -------------------------------------------------------------------------
echo "Test 1: multi-issue dispatch lands in single bare bucket; no --container-mode"
inc
PROJ="$WORKDIR/p1"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_minimal_config "$PROJ"
OUT=$(STUB_WORKTREES="200:foo 201:bar 202:baz" \
      run_dryrun "$PROJ" "$STUB_DIR" 200 201 202)
SPAWN_LOG="$PROJ/spawn-invocations.log"
ok=1
if grep -q -- "--container-mode" "$SPAWN_LOG"; then
  fail_msg "spawn log unexpectedly contains --container-mode"
  cat "$SPAWN_LOG" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT" | grep -qE '^BUCKET: mode=bare issues=.*200.* max='; then
  fail_msg "expected 'BUCKET: mode=bare issues=...200... max=...' line"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
# Exactly ONE bucket (bare); no other mode= lines.
if [ "$ok" = "1" ] && [ "$(echo "$OUT" | grep -cE '^BUCKET: mode=')" -ne 1 ]; then
  fail_msg "expected exactly one BUCKET line; got $(echo "$OUT" | grep -cE '^BUCKET: mode=')"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && [ "$(wc -l < "$SPAWN_LOG")" -lt 3 ]; then
  fail_msg "expected 3 spawn invocations (one per issue), got $(wc -l < "$SPAWN_LOG")"
  cat "$SPAWN_LOG" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "3 spawns in bare bucket, no --container-mode flag"

# -------------------------------------------------------------------------
# Test 2: single-issue short-circuit also bare; no --container-mode
# -------------------------------------------------------------------------
echo "Test 2: single-issue short-circuit lands in bare bucket; no --container-mode"
inc
PROJ="$WORKDIR/p2"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_minimal_config "$PROJ"
OUT=$(STUB_WORKTREES="100:a" \
      run_dryrun "$PROJ" "$STUB_DIR" 100)
SPAWN_LOG="$PROJ/spawn-invocations.log"
if grep -q -- "--container-mode" "$SPAWN_LOG"; then
  fail_msg "single-issue spawn log unexpectedly contains --container-mode"
  cat "$SPAWN_LOG" | sed 's/^/    /'
elif [ "$(wc -l < "$SPAWN_LOG")" -lt 1 ]; then
  fail_msg "expected 1 spawn invocation, got $(wc -l < "$SPAWN_LOG")"
else
  pass_msg "single-issue spawn lacks --container-mode"
fi

# -------------------------------------------------------------------------
# Test 3: legacy PIPELINE_EVAL_* env vars are no-ops (universal invariant)
#
# The pipeline.config knobs PIPELINE_EVAL_CLASSIFIER / PIPELINE_EVAL_CONTAINERS
# / PIPELINE_EVAL_ISOLATION are dead post-#514. Asserting they have no effect
# on dispatch shape pins the always-inline contract.
# -------------------------------------------------------------------------
echo "Test 3: legacy PIPELINE_EVAL_* env vars do not re-introduce --container-mode"
inc
PROJ="$WORKDIR/p3"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER="/nonexistent/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval mock-web-eval"
PIPELINE_EVAL_ISOLATION="container"
EOF
OUT=$(STUB_WORKTREES="300:x 301:y" \
      run_dryrun "$PROJ" "$STUB_DIR" 300 301)
SPAWN_LOG="$PROJ/spawn-invocations.log"
ok=1
if grep -q -- "--container-mode" "$SPAWN_LOG"; then
  fail_msg "spawn log contains --container-mode despite #514 always-inline contract"
  cat "$SPAWN_LOG" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && [ "$(echo "$OUT" | grep -cE '^BUCKET: mode=')" -ne 1 ]; then
  fail_msg "expected exactly one BUCKET line; got $(echo "$OUT" | grep -cE '^BUCKET: mode=')"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT" | grep -qE '^BUCKET: mode=bare '; then
  fail_msg "expected BUCKET: mode=bare line"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "legacy PIPELINE_EVAL_* vars are inert; everything bare, no --container-mode"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
