#!/bin/bash
set -uo pipefail

# Tests for queue partitioning by pre-spawn classifier output in
# scripts/run-queue.sh.template (issue #218).
#
# Uses PIPELINE_QUEUE_DRY_RUN=1 to short-circuit the poll loop after
# initial classification + first fill_slots. Stubs:
#   - gh:       returns canned labels/PR-list output
#   - tmux:     no-op; never matters in dry-run
#   - git:      returns canned worktree-list output so find_worktree resolves
#   - spawn-claude.sh: logs argv to $PROJ/spawn-invocations.log and exits 0
#   - eval-classifier-invoke.sh: emits --container-mode=<x> for issues in a set

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/run-queue.sh.template"

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
  chmod +x "$proj/.claude/scripts/run-queue.sh"
  # Real helper from scripts/ (already in repo)
  cp "$SCRIPT_DIR/../scripts/eval-classifier-invoke.sh" "$proj/scripts/eval-classifier-invoke.sh" 2>/dev/null || {
    mkdir -p "$proj/scripts"
    cp "$SCRIPT_DIR/../scripts/eval-classifier-invoke.sh" "$proj/scripts/eval-classifier-invoke.sh"
  }
  chmod +x "$proj/scripts/eval-classifier-invoke.sh"
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

write_classifier() {
  # Writes a classifier script that emits --container-mode=<MODE> for issues
  # in CLASSIFIER_WEB_ISSUES (space-separated list); empty otherwise.
  # CLASSIFIER_FAIL_ISSUES exits 2 for those issues.
  # CLASSIFIER_EXTRA_TOKENS appends each space-separated token for web issues.
  local path="$1"
  cat > "$path" <<'EOF'
#!/bin/bash
ISSUE="$1"
for fi in ${CLASSIFIER_FAIL_ISSUES:-}; do
  if [ "$ISSUE" = "$fi" ]; then
    echo "stub-classifier: refusing #$ISSUE" >&2
    exit 2
  fi
done
for wi in ${CLASSIFIER_WEB_ISSUES:-}; do
  if [ "$ISSUE" = "$wi" ]; then
    echo "--container-mode=web-eval"
    for tok in ${CLASSIFIER_EXTRA_TOKENS:-}; do
      echo "$tok"
    done
    exit 0
  fi
done
exit 0
EOF
  chmod +x "$path"
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
      bash .claude/scripts/run-queue.sh "$@" 2>&1
  )
}

# -------------------------------------------------------------------------
# Test 1: classifier unset -> single bare bucket, no --container-mode flags
# -------------------------------------------------------------------------
echo "Test 1: classifier unset -> single bare bucket preserves today's behavior"
inc
PROJ="$WORKDIR/p1"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=""
PIPELINE_EVAL_CONTAINERS=""
EOF
STUB_WORKTREES="200:foo 201:bar 202:baz" \
OUT=$(STUB_WORKTREES="200:foo 201:bar 202:baz" \
      run_dryrun "$PROJ" "$STUB_DIR" 200 201 202)
SPAWN_LOG="$PROJ/spawn-invocations.log"
if grep -q -- "--container-mode" "$SPAWN_LOG"; then
  fail_msg "spawn log unexpectedly contains --container-mode when classifier unset"
elif ! echo "$OUT" | grep -qE '^BUCKET: mode=bare issues=.*200.* max='; then
  fail_msg "expected 'BUCKET: mode=bare issues=...200... max=...' line"
  echo "$OUT" | sed 's/^/    /'
elif [ "$(wc -l < "$SPAWN_LOG")" -lt 3 ]; then
  fail_msg "expected 3 spawn invocations (one per issue), got $(wc -l < "$SPAWN_LOG")"
  cat "$SPAWN_LOG" | sed 's/^/    /'
else
  pass_msg "classifier unset -> 3 spawns in bare bucket, no --container-mode flag"
fi

# -------------------------------------------------------------------------
# Test 2: classifier emits web-eval for one issue -> two buckets
# -------------------------------------------------------------------------
echo "Test 2: classifier partitions into web-eval (cap 1) + bare (cap N)"
inc
PROJ="$WORKDIR/p2"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_classifier "$PROJ/.claude/scripts/classifier.sh"
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
EOF
OUT=$(STUB_WORKTREES="100:a 101:b 102:c 103:d" \
      CLASSIFIER_WEB_ISSUES="100" \
      run_dryrun "$PROJ" "$STUB_DIR" 100 101 102 103)
SPAWN_LOG="$PROJ/spawn-invocations.log"

ok=1
echo "$OUT" | grep -qE '^BUCKET: mode=web-eval issues=.*100.* max=1$'  || { fail_msg "missing 'BUCKET: mode=web-eval issues=...100... max=1' line"; ok=0; }
[ "$ok" = "1" ] && (echo "$OUT" | grep -qE '^BUCKET: mode=bare issues=' || { fail_msg "missing 'BUCKET: mode=bare ...' line"; ok=0; })

# Issue 100 invocation carries --container-mode=web-eval
if [ "$ok" = "1" ]; then
  if ! grep -q '100.*--container-mode=web-eval\|--container-mode=web-eval.*100' "$SPAWN_LOG"; then
    fail_msg "spawn log for issue 100 missing --container-mode=web-eval"
    cat "$SPAWN_LOG" | sed 's/^/    /'
    ok=0
  fi
fi
# Issues 101/102/103 do NOT carry --container-mode
if [ "$ok" = "1" ]; then
  for ish in 101 102 103; do
    if grep "$ish" "$SPAWN_LOG" | grep -q -- "--container-mode"; then
      fail_msg "issue $ish unexpectedly has --container-mode flag in spawn log"
      ok=0
      break
    fi
  done
fi
[ "$ok" = "1" ] && pass_msg "web-eval bucket cap=1 with issue 100; bare bucket with 101/102/103"

# -------------------------------------------------------------------------
# Test 3: per-mode MAX_CONCURRENT override
# -------------------------------------------------------------------------
echo "Test 3: PIPELINE_EVAL_CONTAINER_<m>_MAX_CONCURRENT=2 -> web-eval cap=2"
inc
PROJ="$WORKDIR/p3"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_classifier "$PROJ/.claude/scripts/classifier.sh"
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
PIPELINE_EVAL_CONTAINER_web_eval_MAX_CONCURRENT="2"
EOF
OUT=$(STUB_WORKTREES="100:a 101:b" \
      CLASSIFIER_WEB_ISSUES="100 101" \
      run_dryrun "$PROJ" "$STUB_DIR" 100 101)
if echo "$OUT" | grep -qE '^BUCKET: mode=web-eval .* max=2$'; then
  pass_msg "per-mode max=2 honored"
else
  fail_msg "expected web-eval bucket with max=2"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 4: single-issue short-circuit threads --container-mode through
# -------------------------------------------------------------------------
echo "Test 4: single-issue short-circuit honors classifier output"
inc
PROJ="$WORKDIR/p4"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_classifier "$PROJ/.claude/scripts/classifier.sh"
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
EOF
OUT=$(STUB_WORKTREES="100:a" \
      CLASSIFIER_WEB_ISSUES="100" \
      run_dryrun "$PROJ" "$STUB_DIR" 100)
SPAWN_LOG="$PROJ/spawn-invocations.log"
if grep -q -- "--container-mode=web-eval" "$SPAWN_LOG"; then
  pass_msg "single-issue short-circuit spawn carries --container-mode=web-eval"
else
  fail_msg "spawn log missing --container-mode=web-eval"
  cat "$SPAWN_LOG" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 5: classifier rc!=0 -> issue skipped with reason logged
# -------------------------------------------------------------------------
echo "Test 5: classifier non-zero exit skips that issue"
inc
PROJ="$WORKDIR/p5"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_classifier "$PROJ/.claude/scripts/classifier.sh"
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
EOF
OUT=$(STUB_WORKTREES="100:a 101:b 102:c" \
      CLASSIFIER_FAIL_ISSUES="100" \
      run_dryrun "$PROJ" "$STUB_DIR" 100 101 102)
SPAWN_LOG="$PROJ/spawn-invocations.log"
ok=1
if ! echo "$OUT" | grep -qE 'SKIPPED issue=100 reason='; then
  fail_msg "missing 'SKIPPED issue=100 reason=...' line"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && grep -q '^100\b\| 100 ' "$SPAWN_LOG"; then
  fail_msg "issue 100 unexpectedly spawned despite classifier failure"
  cat "$SPAWN_LOG" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! grep -q '101' "$SPAWN_LOG"; then
  fail_msg "issue 101 should have spawned despite 100 failure"
  cat "$SPAWN_LOG" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "issue 100 skipped; 101/102 still proceed"

# -------------------------------------------------------------------------
# Test 6: classifier extra tokens forwarded via --classifier-passthrough
# -------------------------------------------------------------------------
echo "Test 6: classifier extra tokens forwarded via --classifier-passthrough"
inc
PROJ="$WORKDIR/p6"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_classifier "$PROJ/.claude/scripts/classifier.sh"
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
EOF
OUT=$(STUB_WORKTREES="100:a" \
      CLASSIFIER_WEB_ISSUES="100" \
      CLASSIFIER_EXTRA_TOKENS="--foo=bar" \
      run_dryrun "$PROJ" "$STUB_DIR" 100 101)
SPAWN_LOG="$PROJ/spawn-invocations.log"
INVOCATION_100=$(grep '100' "$SPAWN_LOG" | head -1)
if echo "$INVOCATION_100" | grep -q -- "--container-mode=web-eval" \
   && echo "$INVOCATION_100" | grep -q -- "--classifier-passthrough=--foo=bar"; then
  pass_msg "issue 100 spawn carries both --container-mode and --classifier-passthrough"
else
  fail_msg "issue 100 spawn missing one of: --container-mode=web-eval, --classifier-passthrough=--foo=bar"
  echo "    invocation: $INVOCATION_100"
fi

# -------------------------------------------------------------------------
# Test 7: classify_issue resolves PR via `gh pr list --search linked:<issue>`
# The plan documents the classifier receives an issue and a PR number; the
# existing pattern in this repo (check-ci-fix-loop.sh, review-audits.sh) is
# `linked:<issue>` which works on real GitHub repos. `head:<prefix>` does
# not — it requires an exact ref. This test asserts the right qualifier is
# used so the consumer classifier actually receives a usable PR number.
# -------------------------------------------------------------------------
echo "Test 7: classify_issue uses gh pr list --search linked:<issue>"
inc
PROJ="$WORKDIR/p7"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_classifier "$PROJ/.claude/scripts/classifier.sh"
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
EOF
OUT=$(STUB_WORKTREES="500:a 501:b" \
      CLASSIFIER_WEB_ISSUES="" \
      run_dryrun "$PROJ" "$STUB_DIR" 500 501)
GH_LOG="$PROJ/gh-invocations.log"
if grep -q 'pr list .*--search linked:500' "$GH_LOG" \
   && grep -q 'pr list .*--search linked:501' "$GH_LOG"; then
  pass_msg "classify_issue invokes gh pr list with --search linked:<issue>"
else
  fail_msg "expected --search linked:<issue> in gh invocations; got:"
  cat "$GH_LOG" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 8: EVENT: agent-skipped line emitted for classifier-rejected issues
# Observability: skipped issues should be discoverable in queue logs the
# same way agent-launched / agent-finished are.
# -------------------------------------------------------------------------
echo "Test 8: skipped issues emit EVENT: agent-skipped line"
inc
PROJ="$WORKDIR/p8"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
write_classifier "$PROJ/.claude/scripts/classifier.sh"
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="web-eval"
EOF
OUT=$(STUB_WORKTREES="600:a 601:b" \
      CLASSIFIER_FAIL_ISSUES="600" \
      run_dryrun "$PROJ" "$STUB_DIR" 600 601)
if echo "$OUT" | grep -qE 'EVENT: agent-skipped issue=600 reason='; then
  pass_msg "skipped issue 600 emitted EVENT: agent-skipped line"
else
  fail_msg "missing 'EVENT: agent-skipped issue=600 reason=...' line"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 9: classifier unset -> NO gh pr list call (short-circuit)
# When PIPELINE_EVAL_CLASSIFIER is empty, the helper exits early without
# the consumer's classifier running. The pre-classify gh lookup is wasted
# work in that case — short-circuit it.
# -------------------------------------------------------------------------
echo "Test 9: classifier unset short-circuits pre-classify gh pr list call"
inc
PROJ="$WORKDIR/p9"
setup_proj "$PROJ"
STUB_DIR=$(make_stubs "$PROJ")
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=""
PIPELINE_EVAL_CONTAINERS=""
EOF
OUT=$(STUB_WORKTREES="700:a 701:b 702:c" \
      run_dryrun "$PROJ" "$STUB_DIR" 700 701 702)
GH_LOG="$PROJ/gh-invocations.log"
if grep -q 'pr list' "$GH_LOG"; then
  fail_msg "expected zero 'gh pr list' calls when classifier unset; got:"
  cat "$GH_LOG" | sed 's/^/    /'
else
  pass_msg "no 'gh pr list' calls when PIPELINE_EVAL_CLASSIFIER is empty"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
