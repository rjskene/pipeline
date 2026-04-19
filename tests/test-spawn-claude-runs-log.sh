#!/bin/bash
set -euo pipefail

# Tests for runs.log emission + --session-id propagation in spawn-claude.sh.template:
#   - UUID generated and echoed in dry-run output
#   - runs.log line appended with correct TSV columns
#   - PIPELINE_RUNS_LOG_OVERRIDE respected so the real log is not touched
#   - --session-id flag injected into CLAUDE_ARGV in the rendered launcher
#
# Runs spawn-claude.sh with PIPELINE_SPAWN_DRY_RUN=1 and a stubbed `gh` so no
# network is required. Follows the pattern of test-path-picker.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh.template"

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
mkdir -p "$PROJ/.claude/scripts"
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ/.claude/scripts/spawn-claude.sh"

cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_WIN_TEMP=""
PIPELINE_PATH_A_SKILLS_EXECUTE=""
PIPELINE_PATH_B_SKILLS_EXECUTE=""
PIPELINE_PATH_C_SKILLS_EXECUTE=""
PIPELINE_PATH_A_REVIEWER_EXECUTE=""
PIPELINE_PATH_B_REVIEWER_EXECUTE=""
PIPELINE_PATH_C_REVIEWER_EXECUTE=""
EOF

mkdir -p "$PROJ/worktree"

# Stub gh: returns labels from STUB_LABELS, or exits 1 if STUB_GH_FAIL=1.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
if [ "${STUB_GH_FAIL:-0}" = "1" ]; then
  exit 1
fi
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$STUB_DIR/gh"

RUNS_LOG="$WORKDIR/runs.log"

run_dryrun() {
  local labels="$1" issue="$2"
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    STUB_LABELS="$labels" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
    bash .claude/scripts/spawn-claude.sh "$PROJ/worktree" "$issue" slug tmux 2>/dev/null
  cd - >/dev/null
}

# -------------------------------------------------------------------------
# Test 1: dry-run output includes GENERATED_SESSION_ID in valid UUID form
# -------------------------------------------------------------------------
echo "Test 1: dry-run output exposes a valid UUID"
inc
OUT=$(run_dryrun "" 900)
UUID_LINE=$(echo "$OUT" | grep -E '^GENERATED_SESSION_ID=' || true)
if [ -z "$UUID_LINE" ]; then
  fail_msg "no GENERATED_SESSION_ID line in dry-run output"
else
  UUID_VALUE=${UUID_LINE#GENERATED_SESSION_ID=}
  if [[ "$UUID_VALUE" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    pass_msg "UUID matches shape: $UUID_VALUE"
  else
    fail_msg "UUID shape invalid: '$UUID_VALUE'"
  fi
fi

# -------------------------------------------------------------------------
# Test 2: runs.log line appended with all six columns
# -------------------------------------------------------------------------
echo "Test 2: runs.log line has correct TSV columns"
inc
if [ ! -f "$RUNS_LOG" ]; then
  fail_msg "runs.log not created at $RUNS_LOG"
else
  LINE=$(tail -1 "$RUNS_LOG")
  ok=1
  echo "$LINE" | grep -qE $'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\t' || { fail_msg "line missing leading iso-utc timestamp"; ok=0; }
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -qE $'\tsession=[0-9a-f-]{36}\t' || { fail_msg "line missing session= uuid"; ok=0; }; fi
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -q $'\tissue=900\t' || { fail_msg "line missing issue=900"; ok=0; }; fi
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -q $'\tpath=B\t' || { fail_msg "line missing path=B"; ok=0; }; fi
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -q $'\tskill=execute-issue-plan\t' || { fail_msg "line missing skill=execute-issue-plan"; ok=0; }; fi
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -q $'\tworktree='"$PROJ/worktree"'$' || { fail_msg "line missing worktree=$PROJ/worktree"; ok=0; }; fi
  [ "$ok" = "1" ] && pass_msg "all six columns present: $LINE"
fi

# -------------------------------------------------------------------------
# Test 3: runs.log path overrides honored
# -------------------------------------------------------------------------
echo "Test 3: PIPELINE_RUNS_LOG_OVERRIDE is honored"
inc
if echo "$OUT" | grep -q "RUNS_LOG=$RUNS_LOG"; then
  pass_msg "dry-run echoes RUNS_LOG=$RUNS_LOG"
else
  fail_msg "dry-run output missing 'RUNS_LOG=$RUNS_LOG'"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 4: UUID in GENERATED_SESSION_ID matches the session= field in runs.log
# -------------------------------------------------------------------------
echo "Test 4: GENERATED_SESSION_ID == runs.log session= field"
inc
UUID_OUT=$(echo "$OUT" | sed -n 's/^GENERATED_SESSION_ID=//p' | head -1)
UUID_LOG=$(tail -1 "$RUNS_LOG" | sed -E 's/.*\tsession=([0-9a-f-]+)\t.*/\1/')
if [ -n "$UUID_OUT" ] && [ "$UUID_OUT" = "$UUID_LOG" ]; then
  pass_msg "UUID in dry-run output matches runs.log session= ($UUID_OUT)"
else
  fail_msg "UUID mismatch: dry-run='$UUID_OUT' runs.log='$UUID_LOG'"
fi

# -------------------------------------------------------------------------
# Test 5: path label flows into runs.log (docs-only -> path=A)
# -------------------------------------------------------------------------
echo "Test 5: docs-only label -> path=A in runs.log"
inc
: > "$RUNS_LOG"
OUT2=$(run_dryrun "docs-only" 901)
LINE2=$(tail -1 "$RUNS_LOG")
if echo "$LINE2" | grep -q $'\tpath=A\t'; then
  pass_msg "runs.log row for issue 901 has path=A"
else
  fail_msg "expected path=A, got line: $LINE2"
fi

# -------------------------------------------------------------------------
# Test 6: multi-task label -> path=C
# -------------------------------------------------------------------------
echo "Test 6: multi-task label -> path=C in runs.log"
inc
: > "$RUNS_LOG"
OUT3=$(run_dryrun "multi-task" 902)
LINE3=$(tail -1 "$RUNS_LOG")
if echo "$LINE3" | grep -q $'\tpath=C\t'; then
  pass_msg "runs.log row for issue 902 has path=C"
else
  fail_msg "expected path=C, got line: $LINE3"
fi

# -------------------------------------------------------------------------
# Test 7: --session-id injected into CLAUDE_ARGV with UUID interpolated
# -------------------------------------------------------------------------
# The dry-run block dumps the rendered BUILD_ARGV; it should contain the
# literal CLAUDE_ARGV+=(--session-id '<uuid>') line with the UUID.
echo "Test 7: rendered BUILD_ARGV contains CLAUDE_ARGV+=(--session-id '<uuid>')"
inc
: > "$RUNS_LOG"
OUT7=$(run_dryrun "" 903)
UUID_EXPECTED=$(echo "$OUT7" | sed -n 's/^GENERATED_SESSION_ID=//p' | head -1)
BUILD_BLOCK=$(echo "$OUT7" | sed -n '/^=== BUILD_ARGV ===$/,/^=== END BUILD_ARGV ===$/p')
if [ -z "$UUID_EXPECTED" ]; then
  fail_msg "no GENERATED_SESSION_ID in dry-run output"
elif echo "$BUILD_BLOCK" | grep -qF "CLAUDE_ARGV+=(--session-id '$UUID_EXPECTED')"; then
  pass_msg "BUILD_ARGV contains CLAUDE_ARGV+=(--session-id '<uuid>')"
else
  fail_msg "BUILD_ARGV does not contain --session-id with UUID '$UUID_EXPECTED'"
  echo "$BUILD_BLOCK" | sed 's/^/    /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
