#!/bin/bash
set -euo pipefail

# Acceptance test for scripts/spawn-codex.sh — the Codex analog of spawn-claude.sh
# (issue #983, Codex dual-target migration). Runs the script with
# PIPELINE_SPAWN_DRY_RUN=1 and a stubbed `gh` (no network, no live Codex) and
# asserts the rendered dump:
#
#   - launches `codex exec` (the Codex non-interactive verb, vs `claude -p`)
#   - appends the Codex autonomy flags (--sandbox danger-full-access,
#     --ask-for-approval never)
#   - appends --dangerously-bypass-hook-trust
#   - threads the SAME positional argv / env SHAPE as spawn-claude.sh
#     (worktree / issue / slug / mode -> PATH_LETTER, GENERATED_SESSION_ID,
#      --session-id binding, runs.log TSV row, CLAUDE_PIPELINE_ISSUE_NUMBER)
#
# Follows tests/test-spawn-claude-runs-log.sh harness conventions: stub-on-PATH
# gh, PIPELINE_SPAWN_DRY_RUN dump hook, pass_msg/fail_msg/inc counters,
# mktemp -d + trap-rm-on-EXIT.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-codex.sh"

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
# Copy the codex transport AND its sibling helpers (platform.sh etc.) so the
# self-resolve sources don't escape to the real plugin tree.
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/spawn-codex.sh"
chmod +x "$PROJ/.claude/scripts/spawn-codex.sh"
for helper in platform.sh _logging.sh _resolve-plugin-root.sh; do
  if [ -f "$SCRIPT_DIR/../scripts/$helper" ]; then
    cp "$SCRIPT_DIR/../scripts/$helper" "$PROJ/.claude/scripts/$helper"
  fi
done

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

# Stub gh: returns labels from STUB_LABELS (default empty -> path=B).
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$STUB_DIR/gh"

RUNS_LOG="$WORKDIR/runs.log"

run_dryrun() {
  local issue="$1" slug="$2" mode="$3"
  ( cd "$PROJ"
    PATH="$STUB_DIR:$PATH" \
      PIPELINE_SPAWN_DRY_RUN=1 \
      PIPELINE_LOGS_ENABLED=true \
      PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
      bash .claude/scripts/spawn-codex.sh "$PROJ/worktree" "$issue" "$slug" "$mode" 2>/dev/null
  )
}

: > "$RUNS_LOG"
OUT=$(run_dryrun 950 myslug tmux)
BUILD_BLOCK=$(echo "$OUT" | sed -n '/^=== BUILD_ARGV ===$/,/^=== END BUILD_ARGV ===$/p')

# -------------------------------------------------------------------------
# Test 1: launch verb is `codex exec` (NOT `claude -p`)
# -------------------------------------------------------------------------
echo "Test 1: rendered LAUNCH_CMD is 'codex exec'"
inc
if echo "$BUILD_BLOCK" | grep -qE 'declare -a LAUNCH_CMD=\(codex exec\)'; then
  pass_msg "BUILD_ARGV declares LAUNCH_CMD=(codex exec)"
else
  fail_msg "BUILD_ARGV missing 'declare -a LAUNCH_CMD=(codex exec)'"
  echo "$BUILD_BLOCK" | sed 's/^/    /'
fi

inc
if echo "$BUILD_BLOCK" | grep -q 'claude -p'; then
  fail_msg "BUILD_ARGV unexpectedly contains 'claude -p' (should be codex exec)"
else
  pass_msg "BUILD_ARGV does not launch 'claude -p'"
fi

# -------------------------------------------------------------------------
# Test 2: Codex autonomy flags appended (--sandbox danger-full-access,
#         --ask-for-approval never)
# -------------------------------------------------------------------------
echo "Test 2: Codex autonomy flags present in argv"
inc
if echo "$BUILD_BLOCK" | grep -qF "CODEX_ARGV+=(--sandbox)" \
   && echo "$BUILD_BLOCK" | grep -qF "CODEX_ARGV+=(danger-full-access)"; then
  pass_msg "--sandbox danger-full-access appended to CODEX_ARGV"
else
  fail_msg "--sandbox danger-full-access not appended to CODEX_ARGV"
  echo "$BUILD_BLOCK" | sed 's/^/    /'
fi

inc
if echo "$BUILD_BLOCK" | grep -qF "CODEX_ARGV+=(--ask-for-approval)" \
   && echo "$BUILD_BLOCK" | grep -qF "CODEX_ARGV+=(never)"; then
  pass_msg "--ask-for-approval never appended to CODEX_ARGV"
else
  fail_msg "--ask-for-approval never not appended to CODEX_ARGV"
  echo "$BUILD_BLOCK" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 3: --dangerously-bypass-hook-trust appended
# -------------------------------------------------------------------------
echo "Test 3: --dangerously-bypass-hook-trust present in argv"
inc
if echo "$BUILD_BLOCK" | grep -qF "CODEX_ARGV+=(--dangerously-bypass-hook-trust)"; then
  pass_msg "--dangerously-bypass-hook-trust appended to CODEX_ARGV"
else
  fail_msg "--dangerously-bypass-hook-trust not appended to CODEX_ARGV"
  echo "$BUILD_BLOCK" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 4: positional/env SHAPE mirrors spawn-claude.sh
#   - PATH_LETTER derived from labels (empty labels -> B)
#   - GENERATED_SESSION_ID is a valid UUID and bound via --session-id
#   - issue threaded into CLAUDE_PIPELINE_ISSUE_NUMBER
# -------------------------------------------------------------------------
echo "Test 4: positional/env SHAPE mirrors spawn-claude (issue/session threaded)"
inc
PATH_LINE=$(echo "$OUT" | sed -n 's/^PATH_LETTER=//p' | head -1)
if [ "$PATH_LINE" = "B" ]; then
  pass_msg "PATH_LETTER=B for unlabelled issue (same label->path mapping)"
else
  fail_msg "expected PATH_LETTER=B, got '$PATH_LINE'"
fi

inc
UUID_VALUE=$(echo "$OUT" | sed -n 's/^GENERATED_SESSION_ID=//p' | head -1)
if [[ "$UUID_VALUE" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  pass_msg "GENERATED_SESSION_ID is a valid UUID: $UUID_VALUE"
else
  fail_msg "GENERATED_SESSION_ID not a valid UUID: '$UUID_VALUE'"
fi

inc
if [ -n "$UUID_VALUE" ] \
   && echo "$BUILD_BLOCK" | grep -qF "CODEX_ARGV+=(--session-id '$UUID_VALUE')"; then
  pass_msg "--session-id bound to the generated UUID (1:1 join key)"
else
  fail_msg "--session-id not bound to GENERATED_SESSION_ID '$UUID_VALUE'"
  echo "$BUILD_BLOCK" | sed 's/^/    /'
fi

inc
if echo "$BUILD_BLOCK" | grep -qF "export CLAUDE_PIPELINE_ISSUE_NUMBER=950"; then
  pass_msg "issue number threaded into CLAUDE_PIPELINE_ISSUE_NUMBER"
else
  fail_msg "issue number not threaded into CLAUDE_PIPELINE_ISSUE_NUMBER"
  echo "$BUILD_BLOCK" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 5: runs.log TSV row shape is byte-for-byte the spawn-claude contract
#   (timestamp \t session= \t issue= \t path= \t skill= \t worktree=)
# -------------------------------------------------------------------------
echo "Test 5: runs.log TSV row mirrors the spawn-claude join-key contract"
inc
if [ ! -f "$RUNS_LOG" ]; then
  fail_msg "runs.log not created at $RUNS_LOG"
else
  LINE=$(tail -1 "$RUNS_LOG")
  ok=1
  echo "$LINE" | grep -qE $'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\t' || { fail_msg "row missing leading iso-utc timestamp"; ok=0; }
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -qE $'\tsession='"$UUID_VALUE"$'\t' || { fail_msg "row session= != GENERATED_SESSION_ID"; ok=0; }; fi
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -q $'\tissue=950\t' || { fail_msg "row missing issue=950"; ok=0; }; fi
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -q $'\tpath=B\t' || { fail_msg "row missing path=B"; ok=0; }; fi
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -q $'\tskill=execute-issue-plan\t' || { fail_msg "row missing skill=execute-issue-plan"; ok=0; }; fi
  if [ "$ok" = "1" ]; then echo "$LINE" | grep -qE $'\tworktree='"$PROJ/worktree"$'($|\t)' || { fail_msg "row missing worktree=$PROJ/worktree"; ok=0; }; fi
  [ "$ok" = "1" ] && pass_msg "runs.log row mirrors the spawn-claude TSV contract: $LINE"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
