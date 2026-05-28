#!/bin/bash
set -uo pipefail

# Tests for scripts/run-queue.sh worktree-lookup robustness:
# - BOTH bare `wt-<N>` AND slugged `wt-<N>-<slug>` basenames must be discovered
# - Substring collisions must NOT match (issue 4 != wt-42, issue 42 != wt-481)
#
# Sibling of #365's fix to cleanup-worktree.sh (see
# tests/test-cleanup-worktree-naming.sh for the conceptually-identical shape).
#
# Strategy: drive run-queue.sh with PIPELINE_QUEUE_DRY_RUN=1 (precedent in
# tests/test-run-queue-partitioning.sh). Read the spawn-claude argv log to
# determine which worktree the script resolved for the queried issue.

export PIPELINE_LOGS_ENABLED=true

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
# Track materialized worktree paths so we can clean them up at exit.
MATERIALIZED_WTS=()
cleanup() {
  rm -rf "$WORKDIR"
  for wt in "${MATERIALIZED_WTS[@]:-}"; do
    [ -n "$wt" ] && rm -rf "$wt"
  done
}
trap cleanup EXIT

setup_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs" "$proj/mock-web-eval/scripts"
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

# Build PATH stubs for tmux, gh, git. The git stub returns a single
# `worktree list --porcelain` line for $STUB_WT_PATH.
make_stubs() {
  local proj="$1"
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"

  cat > "$stub_dir/tmux" <<'EOF'
#!/bin/bash
exit 0
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
  # STUB_WT_PATH is the only worktree path emitted, simulating the case
  # under test (bare, slugged, or substring-decoy).
  if [ -n "${STUB_WT_PATH:-}" ]; then
    echo "worktree ${STUB_WT_PATH}"
    echo "HEAD abc123"
    echo "branch refs/heads/feature/foo"
    echo ""
  fi
fi
EOF
  chmod +x "$stub_dir/git"
  echo "$stub_dir"
}

# Drive run-queue.sh in dry-run for a SINGLE issue (so we hit the
# short-circuit at line ~213 — that's one of the three matcher sites).
# Returns: ${run_output}<NUL>${spawn_log_contents}<NUL>${exit_code} on stdout
# split by newlines for the caller.
#
# Args: $1 proj, $2 stub_dir, $3 issue, $4 wt_path (the path the git stub
# will report; may or may not match the issue per the test case).
drive_single() {
  local proj="$1" stub_dir="$2" issue="$3" wt_path="$4"
  local spawn_log="$proj/spawn-invocations.log"
  : > "$spawn_log"
  # Materialize the worktree dir so `[ -d $wt_path ]` passes.
  mkdir -p "$wt_path"
  MATERIALIZED_WTS+=("$wt_path")
  local out rc
  out=$(
    cd "$proj" && \
    PATH="$stub_dir:$PATH" \
      TMUX="fakesession" \
      SPAWN_LOG="$spawn_log" \
      PIPELINE_QUEUE_DRY_RUN=1 \
      STUB_WT_PATH="$wt_path" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      bash .claude/scripts/run-queue.sh "$issue" 2>&1
  )
  rc=$?
  printf '%s\n---OUT_END---\n%s\n---SPAWN_END---\n%d\n' \
    "$out" "$(cat "$spawn_log" 2>/dev/null || echo '')" "$rc"
}

# Drive run-queue.sh with TWO issues so we route through
# route_issue -> fill_slots -> launch_agent -> find_worktree (site #3 —
# the function-under-test named by the plan). The git stub still emits
# a SINGLE worktree path; the first issue is the "matchee" and the
# second issue exercises the "no match" path through find_worktree.
#
# Args: $1 proj, $2 stub_dir, $3 issue_a, $4 issue_b, $5 wt_path
drive_multi() {
  local proj="$1" stub_dir="$2" issue_a="$3" issue_b="$4" wt_path="$5"
  local spawn_log="$proj/spawn-invocations.log"
  : > "$spawn_log"
  mkdir -p "$wt_path"
  MATERIALIZED_WTS+=("$wt_path")
  local out rc
  out=$(
    cd "$proj" && \
    PATH="$stub_dir:$PATH" \
      TMUX="fakesession" \
      SPAWN_LOG="$spawn_log" \
      PIPELINE_QUEUE_DRY_RUN=1 \
      STUB_WT_PATH="$wt_path" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      bash .claude/scripts/run-queue.sh "$issue_a" "$issue_b" 2>&1
  )
  rc=$?
  printf '%s\n---OUT_END---\n%s\n---SPAWN_END---\n%d\n' \
    "$out" "$(cat "$spawn_log" 2>/dev/null || echo '')" "$rc"
}

# Drive `bash run-queue.sh --ci-fix <issue> <log-path>` so we exercise
# site #1 (the --ci-fix branch's awk matcher). The --ci-fix branch
# `exec`s the stub spawn-claude.sh on success and prints an "ERROR: No
# worktree for issue ..." line on failure.
#
# Args: $1 proj, $2 stub_dir, $3 issue, $4 wt_path
drive_ci_fix() {
  local proj="$1" stub_dir="$2" issue="$3" wt_path="$4"
  local spawn_log="$proj/spawn-invocations.log"
  : > "$spawn_log"
  mkdir -p "$wt_path"
  MATERIALIZED_WTS+=("$wt_path")
  # --ci-fix requires a log-path argument; just point it at a real file.
  local ci_log="$proj/ci-fix-context.log"
  : > "$ci_log"
  local out rc
  out=$(
    cd "$proj" && \
    PATH="$stub_dir:$PATH" \
      TMUX="fakesession" \
      SPAWN_LOG="$spawn_log" \
      STUB_WT_PATH="$wt_path" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      PIPELINE_PROJECT_ROOT="$proj" \
      bash .claude/scripts/run-queue.sh --ci-fix "$issue" "$ci_log" 2>&1
  )
  rc=$?
  printf '%s\n---OUT_END---\n%s\n---SPAWN_END---\n%d\n' \
    "$out" "$(cat "$spawn_log" 2>/dev/null || echo '')" "$rc"
}

write_config() {
  local proj="$1"
  cat > "$proj/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
EOF
}

# ---- Case 1: bare match (positive) — wt-42 must resolve for issue 42 ----
echo "Case 1: bare worktree wt-42 must resolve for issue 42 (positive)"
inc
PROJ="$WORKDIR/p1"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_single "$PROJ" "$STUB" 42 "/tmp/wt-42")
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42'; then
  pass_msg "case 1 (bare positive) resolved wt-42 for issue 42"
else
  fail_msg "case 1 (bare positive) expected spawn log to reference /tmp/wt-42; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# ---- Case 2: slugged match (positive) — wt-42-foo must resolve for issue 42 ----
echo "Case 2: slugged worktree wt-42-foo must resolve for issue 42 (positive)"
inc
PROJ="$WORKDIR/p2"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_single "$PROJ" "$STUB" 42 "/tmp/wt-42-foo")
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42-foo'; then
  pass_msg "case 2 (slugged positive) resolved wt-42-foo for issue 42"
else
  fail_msg "case 2 (slugged positive) expected spawn log to reference /tmp/wt-42-foo; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# ---- Case 3: substring negative — wt-481 must NOT match issue 42 ----
echo "Case 3: wt-481 must NOT be matched when looking up issue 42 (negative)"
inc
PROJ="$WORKDIR/p3"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_single "$PROJ" "$STUB" 42 "/tmp/wt-481")
OUT_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{exit}{print}')
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
ok=1
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-481'; then
  fail_msg "case 3 (negative) spawn log unexpectedly referenced /tmp/wt-481 when querying issue 42"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT_BLOCK" | grep -q "No worktree found for issue #42"; then
  fail_msg "case 3 (negative) expected 'No worktree found for issue #42'; got:"
  echo "$OUT_BLOCK" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 3 (negative) refuses to match wt-481 for issue 42"

# ---- Case 4: substring negative — wt-42 must NOT match issue 4 ----
echo "Case 4: wt-42 must NOT be matched when looking up issue 4 (negative)"
inc
PROJ="$WORKDIR/p4"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_single "$PROJ" "$STUB" 4 "/tmp/wt-42")
OUT_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{exit}{print}')
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
ok=1
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42'; then
  fail_msg "case 4 (negative) spawn log unexpectedly referenced /tmp/wt-42 when querying issue 4"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT_BLOCK" | grep -q "No worktree found for issue #4"; then
  fail_msg "case 4 (negative) expected 'No worktree found for issue #4'; got:"
  echo "$OUT_BLOCK" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 4 (negative) refuses to match wt-42 for issue 4"

# ============================================================================
# Site #3 — find_worktree() (multi-issue queue path: route_issue -> fill_slots
# -> launch_agent -> find_worktree). Drive with TWO issues so the dry-run
# code path enters launch_agent (which calls find_worktree).
# ============================================================================

# ---- Case 5: find_worktree bare positive — wt-42 must resolve for issue 42 ----
echo "Case 5: find_worktree resolves bare wt-42 for issue 42 (multi-issue path)"
inc
PROJ="$WORKDIR/p5"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
# Pair the matchee (42) with a sentinel (99) that the single emitted
# worktree won't match — keeps the run focused on the find_worktree(42) path.
OUT=$(drive_multi "$PROJ" "$STUB" 42 99 "/tmp/wt-42")
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42'; then
  pass_msg "case 5 (find_worktree bare positive) resolved wt-42 for issue 42"
else
  fail_msg "case 5 (find_worktree bare positive) expected spawn log to reference /tmp/wt-42; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# ---- Case 6: find_worktree slugged positive ----
echo "Case 6: find_worktree resolves slugged wt-42-foo for issue 42 (multi-issue path)"
inc
PROJ="$WORKDIR/p6"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_multi "$PROJ" "$STUB" 42 99 "/tmp/wt-42-foo")
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42-foo'; then
  pass_msg "case 6 (find_worktree slugged positive) resolved wt-42-foo for issue 42"
else
  fail_msg "case 6 (find_worktree slugged positive) expected spawn log to reference /tmp/wt-42-foo; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# ---- Case 7: find_worktree substring negative — wt-481 must NOT match issue 42 ----
echo "Case 7: find_worktree refuses to match wt-481 for issue 42 (multi-issue path, negative)"
inc
PROJ="$WORKDIR/p7"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
# Pair 42 with 99 sentinel — the stub emits /tmp/wt-481 once, so neither
# issue's find_worktree() call should match.
OUT=$(drive_multi "$PROJ" "$STUB" 42 99 "/tmp/wt-481")
OUT_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{exit}{print}')
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
ok=1
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-481'; then
  fail_msg "case 7 (find_worktree negative) spawn log unexpectedly referenced /tmp/wt-481 when querying issue 42"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT_BLOCK" | grep -q "No worktree found for issue #42"; then
  fail_msg "case 7 (find_worktree negative) expected 'No worktree found for issue #42'; got:"
  echo "$OUT_BLOCK" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 7 (find_worktree negative) refuses to match wt-481 for issue 42"

# ---- Case 8: find_worktree substring negative — wt-42 must NOT match issue 4 ----
echo "Case 8: find_worktree refuses to match wt-42 for issue 4 (multi-issue path, negative)"
inc
PROJ="$WORKDIR/p8"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
# Pair 4 with 99 sentinel — stub emits /tmp/wt-42, which should not match issue 4.
OUT=$(drive_multi "$PROJ" "$STUB" 4 99 "/tmp/wt-42")
OUT_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{exit}{print}')
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
ok=1
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42'; then
  fail_msg "case 8 (find_worktree negative) spawn log unexpectedly referenced /tmp/wt-42 when querying issue 4"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT_BLOCK" | grep -q "No worktree found for issue #4"; then
  fail_msg "case 8 (find_worktree negative) expected 'No worktree found for issue #4'; got:"
  echo "$OUT_BLOCK" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 8 (find_worktree negative) refuses to match wt-42 for issue 4"

# ============================================================================
# Site #1 — `--ci-fix` mode awk matcher. Drive `bash run-queue.sh --ci-fix
# <issue> <log>` so the --ci-fix branch's awk predicate is exercised.
# ============================================================================

# ---- Case 9: --ci-fix bare positive ----
echo "Case 9: --ci-fix resolves bare wt-42 for issue 42 (positive)"
inc
PROJ="$WORKDIR/p9"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_ci_fix "$PROJ" "$STUB" 42 "/tmp/wt-42")
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42'; then
  pass_msg "case 9 (--ci-fix bare positive) resolved wt-42 for issue 42"
else
  fail_msg "case 9 (--ci-fix bare positive) expected spawn log to reference /tmp/wt-42; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# ---- Case 10: --ci-fix slugged positive ----
echo "Case 10: --ci-fix resolves slugged wt-42-foo for issue 42 (positive)"
inc
PROJ="$WORKDIR/p10"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_ci_fix "$PROJ" "$STUB" 42 "/tmp/wt-42-foo")
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42-foo'; then
  pass_msg "case 10 (--ci-fix slugged positive) resolved wt-42-foo for issue 42"
else
  fail_msg "case 10 (--ci-fix slugged positive) expected spawn log to reference /tmp/wt-42-foo; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# ---- Case 11: --ci-fix substring negative (wt-481 vs issue 42) ----
echo "Case 11: --ci-fix refuses to match wt-481 for issue 42 (negative)"
inc
PROJ="$WORKDIR/p11"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_ci_fix "$PROJ" "$STUB" 42 "/tmp/wt-481")
OUT_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{exit}{print}')
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
ok=1
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-481'; then
  fail_msg "case 11 (--ci-fix negative) spawn log unexpectedly referenced /tmp/wt-481 when querying issue 42"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT_BLOCK" | grep -q "ERROR: No worktree for issue #42"; then
  fail_msg "case 11 (--ci-fix negative) expected 'ERROR: No worktree for issue #42'; got:"
  echo "$OUT_BLOCK" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 11 (--ci-fix negative) refuses to match wt-481 for issue 42"

# ---- Case 12: --ci-fix substring negative (wt-42 vs issue 4) ----
echo "Case 12: --ci-fix refuses to match wt-42 for issue 4 (negative)"
inc
PROJ="$WORKDIR/p12"
setup_proj "$PROJ"
STUB=$(make_stubs "$PROJ")
write_config "$PROJ"
OUT=$(drive_ci_fix "$PROJ" "$STUB" 4 "/tmp/wt-42")
OUT_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{exit}{print}')
SPAWN_BLOCK=$(echo "$OUT" | awk '/---OUT_END---/{flag=1;next}/---SPAWN_END---/{flag=0}flag')
ok=1
if echo "$SPAWN_BLOCK" | grep -q '/tmp/wt-42'; then
  fail_msg "case 12 (--ci-fix negative) spawn log unexpectedly referenced /tmp/wt-42 when querying issue 4"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = "1" ] && ! echo "$OUT_BLOCK" | grep -q "ERROR: No worktree for issue #4"; then
  fail_msg "case 12 (--ci-fix negative) expected 'ERROR: No worktree for issue #4'; got:"
  echo "$OUT_BLOCK" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 12 (--ci-fix negative) refuses to match wt-42 for issue 4"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
