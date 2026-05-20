#!/bin/bash
set -euo pipefail

# Tests that spawn-claude.sh gates observability log writes on
# PIPELINE_LOGS_ENABLED:
#   - With PIPELINE_LOGS_ENABLED unset/false: no files created under
#     <project>/.claude/logs/ (no runs.log, no per-issue session log).
#   - With PIPELINE_LOGS_ENABLED=true: exactly one TSV line in runs.log.
#
# Uses PIPELINE_SPAWN_DRY_RUN=1 to exit before launching the claude CLI.
# A stub `claude` and stub `gh` are placed on PATH so no network/auth needed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/worktree"

cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_WIN_TEMP=""
PIPELINE_PATH_A_SKILLS_EXECUTE=""
PIPELINE_PATH_B_SKILLS_EXECUTE=""
PIPELINE_PATH_C_SKILLS_EXECUTE=""
PIPELINE_PATH_A_REVIEWER_EXECUTE=""
PIPELINE_PATH_B_REVIEWER_EXECUTE=""
PIPELINE_PATH_C_REVIEWER_EXECUTE=""
EOF

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB_DIR/gh"
cat > "$STUB_DIR/claude" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB_DIR/claude"

run_spawn() {
  local logs_enabled="$1" issue="$2"
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    HOME="$WORKDIR/home" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    PIPELINE_LOGS_ENABLED="$logs_enabled" \
    bash "$SCRIPT_UNDER_TEST" "$PROJ/worktree" "$issue" slug tmux >/dev/null 2>&1
  cd - >/dev/null
}

# Test 1: PIPELINE_LOGS_ENABLED=false (default) -> no logs dir contents
echo "Test 1: PIPELINE_LOGS_ENABLED=false suppresses .claude/logs/ writes"
inc
rm -rf "$PROJ/.claude"
run_spawn "false" 900
if [ -e "$PROJ/.claude/logs/runs.log" ]; then
  fail_msg "runs.log was created despite PIPELINE_LOGS_ENABLED=false"
elif [ -d "$PROJ/.claude/logs" ] && [ -n "$(ls -A "$PROJ/.claude/logs" 2>/dev/null)" ]; then
  fail_msg ".claude/logs/ has files despite PIPELINE_LOGS_ENABLED=false: $(ls -A "$PROJ/.claude/logs")"
else
  pass_msg "no log files created when disabled"
fi

# Test 2: PIPELINE_LOGS_ENABLED=true -> exactly one TSV line in runs.log
echo "Test 2: PIPELINE_LOGS_ENABLED=true emits exactly one runs.log TSV line"
inc
rm -rf "$PROJ/.claude"
run_spawn "true" 901
RUNS_LOG="$PROJ/.claude/logs/runs.log"
if [ ! -f "$RUNS_LOG" ]; then
  fail_msg "runs.log not created at $RUNS_LOG"
else
  LINES=$(wc -l < "$RUNS_LOG")
  LINE=$(tail -1 "$RUNS_LOG")
  if [ "$LINES" -ne 1 ]; then
    fail_msg "expected exactly 1 line in runs.log, got $LINES"
  elif ! echo "$LINE" | grep -q $'\tissue=901\t'; then
    fail_msg "runs.log line missing issue=901: $LINE"
  elif ! echo "$LINE" | grep -q $'\tsession='; then
    fail_msg "runs.log line missing session=: $LINE"
  else
    pass_msg "runs.log has 1 TSV line with expected columns"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
