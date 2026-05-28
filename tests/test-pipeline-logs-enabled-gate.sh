#!/usr/bin/env bash
# Cross-cutting confirmation matrix: every observability writer in the pipeline
# must respect PIPELINE_LOGS_ENABLED. For each writer this test:
#   (a) runs with PIPELINE_LOGS_ENABLED=false, snapshots .claude/logs/ before
#       and after, and asserts no new files appeared;
#   (b) runs with PIPELINE_LOGS_ENABLED=true, and asserts the writer's expected
#       file/glob exists.
#
# This is a "matrix" cross-check on top of the per-writer gate tests; it is
# expected to pass on first run since the underlying gates already landed.
#
# Writers covered:
#   1. scripts/spawn-claude.sh        -> runs.log (+ per-issue session log)
#   2. scripts/run-queue.sh           -> queue-*.log + queue-pending.txt
#   3. scripts/cleanup-worktree.sh    -> tool-use-issue-<N>.log
#   4. scripts/analyze-issues.sh      -> analyze-shortlist-*.json
#   5. scripts/check-ci-fix-loop.sh   -> ci-fix-<N>-attempt-*.log

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SPAWN="$REPO_ROOT/scripts/spawn-claude.sh"
RUN_QUEUE="$REPO_ROOT/scripts/run-queue.sh"
CLEANUP="$REPO_ROOT/scripts/cleanup-worktree.sh"
ANALYZE="$REPO_ROOT/scripts/analyze-issues.sh"
CI_FIX="$REPO_ROOT/scripts/check-ci-fix-loop.sh"
LOGGING_HELPER="$REPO_ROOT/scripts/_logging.sh"

for f in "$SPAWN" "$RUN_QUEUE" "$CLEANUP" "$ANALYZE" "$CI_FIX" "$LOGGING_HELPER"; do
  [ -f "$f" ] || { echo "ERROR: missing required file $f" >&2; exit 1; }
done

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

# snapshot_logs <proj>: list all files under <proj>/.claude/logs (empty if absent)
snapshot_logs() {
  local proj="$1"
  if [ -d "$proj/.claude/logs" ]; then
    (cd "$proj/.claude/logs" && find . -type f 2>/dev/null | sort)
  fi
}

assert_no_new_files() {
  local label="$1" before="$2" after="$3"
  if [ "$before" = "$after" ]; then
    pass_msg "$label: no new files under .claude/logs/ when disabled"
  else
    fail_msg "$label: unexpected files appeared under .claude/logs/"
    echo "    --- before ---"; echo "$before" | sed 's/^/    /'
    echo "    --- after  ---"; echo "$after"  | sed 's/^/    /'
  fi
}

write_pipeline_config() {
  cat > "$1/pipeline.config" <<'EOF'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_WIN_TEMP=""
PIPELINE_TMUX_SESSION="fake"
PIPELINE_PATH_A_SKILLS_EXECUTE=""
PIPELINE_PATH_B_SKILLS_EXECUTE=""
PIPELINE_PATH_C_SKILLS_EXECUTE=""
PIPELINE_PATH_A_REVIEWER_EXECUTE=""
PIPELINE_PATH_B_REVIEWER_EXECUTE=""
PIPELINE_PATH_C_REVIEWER_EXECUTE=""
EOF
}

# =====================================================================
# Writer 1: spawn-claude.sh -> runs.log
# =====================================================================
echo ""
echo "[1/5] spawn-claude.sh -> runs.log"
PROJ="$ROOT_TMP/spawn"; mkdir -p "$PROJ/worktree"
write_pipeline_config "$PROJ"
STUB="$PROJ/stub"; mkdir -p "$STUB"
for c in gh claude; do
  cat > "$STUB/$c" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$STUB/$c"
done

run_spawn() {
  local enabled="$1" issue="$2"
  (
    cd "$PROJ"
    PATH="$STUB:$PATH" \
      HOME="$ROOT_TMP/spawn-home" \
      PIPELINE_SPAWN_DRY_RUN=1 \
      PIPELINE_LOGS_ENABLED="$enabled" \
      bash "$SPAWN" "$PROJ/worktree" "$issue" slug tmux
  ) >/dev/null 2>&1
}

# (a) disabled
inc
BEFORE=$(snapshot_logs "$PROJ")
run_spawn "false" 900
AFTER=$(snapshot_logs "$PROJ")
assert_no_new_files "spawn-claude" "$BEFORE" "$AFTER"

# (b) enabled
inc
run_spawn "true" 901
if [ -f "$PROJ/.claude/logs/runs.log" ] && grep -q $'\tissue=901\t' "$PROJ/.claude/logs/runs.log"; then
  pass_msg "spawn-claude: runs.log exists with issue=901 when enabled"
else
  fail_msg "spawn-claude: runs.log missing or lacks issue=901"
  ls -la "$PROJ/.claude/logs/" 2>&1 | sed 's/^/    /'
fi

# =====================================================================
# Writer 2: run-queue.sh -> queue-*.log + queue-pending.txt
# =====================================================================
echo ""
echo "[2/5] run-queue.sh -> queue-*.log + queue-pending.txt"

setup_queue_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/scripts" "$proj/.claude/logs"
  cp "$RUN_QUEUE"        "$proj/.claude/scripts/run-queue.sh"
  cp "$LOGGING_HELPER"   "$proj/.claude/scripts/_logging.sh"
  chmod +x "$proj/.claude/scripts/run-queue.sh"
  cat > "$proj/.claude/scripts/spawn-claude.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$proj/.claude/scripts/spawn-claude.sh"
  write_pipeline_config "$proj"

  local stub="$proj/stub"; mkdir -p "$stub"
  cat > "$stub/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$stub/gh" <<'EOF'
#!/bin/bash
echo ""
EOF
  cat > "$stub/git" <<'EOF'
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
  chmod +x "$stub/tmux" "$stub/gh" "$stub/git"
}

run_queue_case() {
  local proj="$1" enabled="$2"
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"; slug="${entry##*:}"
    mkdir -p "/tmp/wt-${issue}-${slug}"
  done
  (
    cd "$proj"
    PATH="$proj/stub:$PATH" \
      TMUX="fake" \
      STUB_WORKTREES="${STUB_WORKTREES:-}" \
      PIPELINE_QUEUE_DRY_RUN=1 \
      PIPELINE_LOGS_ENABLED="$enabled" \
      CLAUDE_PLUGIN_ROOT="$proj/.claude" \
      bash .claude/scripts/run-queue.sh 200 201
  ) >/dev/null 2>&1
}

# (a) disabled
inc
PROJ="$ROOT_TMP/queue-off"
setup_queue_proj "$PROJ"
BEFORE=$(snapshot_logs "$PROJ")
STUB_WORKTREES="200:foo 201:bar" run_queue_case "$PROJ" "false"
AFTER=$(snapshot_logs "$PROJ")
assert_no_new_files "run-queue" "$BEFORE" "$AFTER"

# (b) enabled
inc
PROJ="$ROOT_TMP/queue-on"
setup_queue_proj "$PROJ"
STUB_WORKTREES="200:foo 201:bar" run_queue_case "$PROJ" "true"
ok=1
if ! ls "$PROJ/.claude/logs/"queue-*.log >/dev/null 2>&1; then
  fail_msg "run-queue: queue-*.log missing when enabled"
  ls -la "$PROJ/.claude/logs/" 2>&1 | sed 's/^/    /'
  ok=0
fi
if [ "$ok" = 1 ] && [ ! -f "$PROJ/.claude/logs/queue-pending.txt" ]; then
  fail_msg "run-queue: queue-pending.txt missing when enabled"
  ok=0
fi
[ "$ok" = 1 ] && pass_msg "run-queue: queue-*.log + queue-pending.txt present when enabled"

# =====================================================================
# Writer 3: cleanup-worktree.sh -> tool-use-issue-<N>.log
# =====================================================================
echo ""
echo "[3/5] cleanup-worktree.sh -> tool-use-issue-<N>.log"

setup_cleanup_proj() {
  local proj="$1" issue="$2"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/logs"
  write_pipeline_config "$proj"
  local wt="$proj/wt-${issue}-foo"
  mkdir -p "$wt/.claude/logs"
  printf '2026-01-01\tBash\tabc\tls\n' > "$wt/.claude/logs/tool-use.log"

  local stub="$proj/stub"; mkdir -p "$stub"
  cat > "$stub/git" <<EOF
#!/bin/bash
if [ "\$1" = "-C" ]; then shift 2; fi
case "\$1" in
  worktree)
    case "\$2" in
      list) echo "$wt  abc123 [feature/foo]"; exit 0 ;;
      remove|prune) exit 0 ;;
    esac ;;
  rev-parse) echo "feature/foo"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
EOF
  cat > "$stub/gh" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    state|.state) echo "CLOSED"; exit 0 ;;
    number) echo "999"; exit 0 ;;
  esac
done
echo ""
exit 0
EOF
  chmod +x "$stub/git" "$stub/gh"
}

run_cleanup_case() {
  local proj="$1" issue="$2" enabled="$3"
  (
    cd "$proj"
    PATH="$proj/stub:$PATH" \
      PIPELINE_PROJECT_ROOT="$proj" \
      PIPELINE_LOGS_ENABLED="$enabled" \
      bash "$CLEANUP" "$issue" --force
  ) >/dev/null 2>&1
}

# (a) disabled
inc
PROJ="$ROOT_TMP/cleanup-off"
setup_cleanup_proj "$PROJ" 42
BEFORE=$(snapshot_logs "$PROJ")
run_cleanup_case "$PROJ" 42 "false"
AFTER=$(snapshot_logs "$PROJ")
assert_no_new_files "cleanup-worktree" "$BEFORE" "$AFTER"

# (b) enabled
inc
PROJ="$ROOT_TMP/cleanup-on"
setup_cleanup_proj "$PROJ" 43
run_cleanup_case "$PROJ" 43 "true"
if [ -f "$PROJ/.claude/logs/tool-use-issue-43.log" ]; then
  pass_msg "cleanup-worktree: tool-use-issue-43.log copied when enabled"
else
  fail_msg "cleanup-worktree: tool-use-issue-43.log missing when enabled"
  ls -la "$PROJ/.claude/logs/" 2>&1 | sed 's/^/    /'
fi

# =====================================================================
# Writer 4: analyze-issues.sh -> analyze-shortlist-*.json
# =====================================================================
echo ""
echo "[4/5] analyze-issues.sh -> analyze-shortlist-*.json"

setup_analyze_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/fix"
  write_pipeline_config "$proj"
  echo "[]" > "$proj/fix/issues.json"
}

run_analyze_case() {
  local proj="$1" enabled="$2"
  (
    cd "$proj"
    PIPELINE_LOGS_ENABLED="$enabled" \
      bash "$ANALYZE" --fixture "$proj/fix"
  ) >/dev/null 2>&1
}

# (a) disabled
inc
PROJ="$ROOT_TMP/analyze-off"
setup_analyze_proj "$PROJ"
BEFORE=$(snapshot_logs "$PROJ")
run_analyze_case "$PROJ" "false"
AFTER=$(snapshot_logs "$PROJ")
assert_no_new_files "analyze-issues" "$BEFORE" "$AFTER"

# (b) enabled
inc
PROJ="$ROOT_TMP/analyze-on"
setup_analyze_proj "$PROJ"
run_analyze_case "$PROJ" "true"
shopt -s nullglob
matches=( "$PROJ/.claude/logs/analyze-shortlist-"*.json )
shopt -u nullglob
if [ "${#matches[@]}" -ge 1 ]; then
  pass_msg "analyze-issues: analyze-shortlist-*.json created when enabled"
else
  fail_msg "analyze-issues: no analyze-shortlist-*.json when enabled"
  ls -la "$PROJ/.claude/logs/" 2>&1 | sed 's/^/    /'
fi

# =====================================================================
# Writer 5: check-ci-fix-loop.sh -> ci-fix-<N>-attempt-*.log
# =====================================================================
echo ""
echo "[5/5] check-ci-fix-loop.sh -> ci-fix-<N>-attempt-*.log"

setup_cifix_proj() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/stub"
  cat > "$proj/stub/gh" <<'SHIM'
#!/usr/bin/env bash
STATE="${GH_FAKE_STATE:-/tmp/gh-state}"
declare -A S
if [ -f "$STATE" ]; then
  while IFS='=' read -r k v; do S[$k]="$v"; done < "$STATE"
fi
cmd="${1:-}"; sub="${2:-}"
case "$cmd $sub" in
  "issue view")
    json_flag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json_flag="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$json_flag" == *"closedByPullRequestsReferences"* ]]; then
      echo "${S[pr]:-}"; exit 0
    fi
    if [[ "$json_flag" == *"comments"* ]]; then
      echo "${S[retries]:-0}"; exit 0
    fi
    exit 0 ;;
  "pr list") echo ""; exit 0 ;;
  "pr checks")
    json_flag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json_flag="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$json_flag" == "conclusion" ]]; then
      echo "${S[conclusion]:-pending}"; exit 0
    fi
    if [[ "$json_flag" == "link" ]]; then
      echo "https://example.test/runs/${S[run_id]:-0}"; exit 0
    fi
    exit 0 ;;
  "run view") echo "${S[fail_log]:-stub failure log}"; exit 0 ;;
  "issue comment") exit 0 ;;
  "issue edit") exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$proj/stub/gh"
  cat > "$proj/stub/gh-state" <<EOF
conclusion=failure
pr=42
run_id=999
retries=0
fail_log=boom
EOF
}

run_cifix_case() {
  local proj="$1" enabled="$2"
  (
    cd "$proj"
    PATH="$proj/stub:$PATH" \
      GH_FAKE_STATE="$proj/stub/gh-state" \
      PIPELINE_REPO="fake/repo" \
      PIPELINE_CI_FIX_RETRY_BUDGET="2" \
      PIPELINE_CI_FIX_LOG_LINES="200" \
      PIPELINE_LOGS_ENABLED="$enabled" \
      bash "$CI_FIX" 42
  ) >/dev/null 2>&1
}

# (a) disabled
inc
PROJ="$ROOT_TMP/cifix-off"
setup_cifix_proj "$PROJ"
BEFORE=$(snapshot_logs "$PROJ")
run_cifix_case "$PROJ" "false"
AFTER=$(snapshot_logs "$PROJ")
assert_no_new_files "check-ci-fix-loop" "$BEFORE" "$AFTER"

# (b) enabled
inc
PROJ="$ROOT_TMP/cifix-on"
setup_cifix_proj "$PROJ"
run_cifix_case "$PROJ" "true"
if ls "$PROJ/.claude/logs/"ci-fix-42-attempt-*.log >/dev/null 2>&1; then
  pass_msg "check-ci-fix-loop: ci-fix-42-attempt-*.log created when enabled"
else
  fail_msg "check-ci-fix-loop: ci-fix-42-attempt-*.log missing when enabled"
  ls -la "$PROJ/.claude/logs/" 2>&1 | sed 's/^/    /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
