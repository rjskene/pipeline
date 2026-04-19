#!/bin/bash
set -euo pipefail

# Tests for the PATH C delegation enforcement hook
# (.claude-pipeline/hooks/enforce-path-c-delegation.py.template).
#
# The hook is a PreToolUse gate for Edit/Write that:
#   - Exits 0 (allow) if the orchestrator has dispatched a tdd-implementer
#     subagent with a `target=<dir>` sentinel covering the file's directory.
#   - Exits 0 (allow) if the file matches the test/docs/config allowlist.
#   - Exits 0 (allow) if ALLOW_ORCHESTRATOR_EDIT=true.
#   - Exits 0 (allow) if CLAUDE_PIPELINE_ISSUE_NUMBER is unset (not in pipeline).
#   - Exits 0 (allow) if the issue is not labeled `multi-task`.
#   - Exits 0 (allow) if `gh` fails (fail-open).
#   - Exits 2 (block) only when in a PATH C session, on a non-allowlisted
#     impl file, with no covering subagent dispatch.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_TEMPLATE="$SCRIPT_DIR/../hooks/enforce-path-c-delegation.py.template"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$HOOK_TEMPLATE" ]; then
  echo "ERROR: hook template not found at $HOOK_TEMPLATE" >&2
  echo "Test 0: hook template exists"
  inc
  fail_msg "missing $HOOK_TEMPLATE"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Render the template (PIPELINE_REPO is the only var) to a runnable hook.
HOOK="$WORKDIR/enforce-path-c-delegation.py"
PIPELINE_REPO="fake/repo" envsubst '$PIPELINE_REPO' < "$HOOK_TEMPLATE" > "$HOOK"

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/logs/subagents" "$PROJ/web"

# Stub gh on PATH. Returns labels from STUB_LABELS (newline-separated). Fails if STUB_GH_FAIL=1.
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

# Helper: run hook with a stdin JSON payload and given env. Echoes exit code on the last line.
run_hook() {
  local stdin_payload="$1"
  shift
  local out_file="$WORKDIR/out.txt"
  local err_file="$WORKDIR/err.txt"
  cd "$PROJ"
  set +e
  echo "$stdin_payload" | env -i \
    HOME="$HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$PROJ" \
    "$@" \
    python3 "$HOOK" >"$out_file" 2>"$err_file"
  local rc=$?
  set -e
  cd - >/dev/null
  echo "$rc"
}

# Helper: write a synthetic subagent log JSON
write_dispatch() {
  local session_id="$1"
  local subagent_type="$2"
  local prompt_text="$3"
  local description="${4:-test}"
  local file
  file=$(mktemp "$PROJ/.claude/logs/subagents/dispatch-XXXXXX.json")
  python3 - "$file" "$session_id" "$subagent_type" "$prompt_text" "$description" <<'PY'
import json, sys
file, session_id, subagent_type, prompt_text, description = sys.argv[1:6]
with open(file, "w") as f:
    json.dump({
        "schema_version": 1,
        "timestamp_utc": "2026-04-19T00:00:00",
        "session_id": session_id,
        "agent_id": "abc12345-fake",
        "description": description,
        "subagent_type": subagent_type,
        "prompt": prompt_text,
    }, f)
PY
}

# Helper: clear caches and dispatch logs between tests
reset_state() {
  python3 -c "
import os, glob
for f in glob.glob('$PROJ/.claude/logs/subagents/*.json'):
    os.remove(f)
for f in glob.glob('/tmp/claude-path-c-*.cache'):
    try: os.remove(f)
    except FileNotFoundError: pass
"
}

# --- Test 1: CLAUDE_PIPELINE_ISSUE_NUMBER unset -> exit 0 ---
echo "Test 1: no CLAUDE_PIPELINE_ISSUE_NUMBER -> exit 0"
inc
reset_state
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-1"}'
RC=$(run_hook "$PAYLOAD" STUB_LABELS="multi-task")
if [ "$RC" = "0" ]; then pass_msg "exit 0"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 2: non-Edit/Write tool -> exit 0 ---
echo "Test 2: tool_name=Read -> exit 0"
inc
reset_state
PAYLOAD='{"tool_name":"Read","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-1"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (Read)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 3: ALLOW_ORCHESTRATOR_EDIT=true escape hatch -> exit 0 ---
echo "Test 3: ALLOW_ORCHESTRATOR_EDIT=true -> exit 0"
inc
reset_state
PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-1"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task" ALLOW_ORCHESTRATOR_EDIT=true)
if [ "$RC" = "0" ]; then pass_msg "exit 0 (escape hatch)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 4: label not multi-task -> exit 0 ---
echo "Test 4: label=bug (not multi-task) -> exit 0"
inc
reset_state
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-1"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="bug")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (no multi-task label)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 5: gh fails -> exit 0 (fail-open) ---
echo "Test 5: gh fails -> exit 0 (fail-open)"
inc
reset_state
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-1"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_GH_FAIL=1)
if [ "$RC" = "0" ]; then pass_msg "exit 0 (gh fail)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 6: PATH C, no dispatch -> exit 2 (block) ---
echo "Test 6: PATH C + no dispatch + impl file -> exit 2"
inc
reset_state
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-6"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (blocked)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 7: allowlist .test.ts -> exit 0 ---
echo "Test 7: allowlist (web/foo.test.ts) -> exit 0"
inc
reset_state
PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"web/foo.test.ts"},"session_id":"sess-7"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (test file)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 8: allowlist *.md -> exit 0 ---
echo "Test 8: allowlist (README.md) -> exit 0"
inc
reset_state
PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"README.md"},"session_id":"sess-8"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (markdown)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 9: dispatch with target=web/ matches write to web/foo.ts -> exit 0 ---
echo "Test 9: dispatch (target=web/) authorizes write to web/foo.ts -> exit 0"
inc
reset_state
write_dispatch "sess-9" "tdd-implementer" "target=web/" "Add foo route"
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-9"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "0" ]; then pass_msg "exit 0 (dispatched + matches sentinel)"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 10: dispatch target=docs/ does NOT authorize write to web/foo.ts -> exit 2 ---
echo "Test 10: dispatch (target=docs/) does NOT authorize web/foo.ts -> exit 2"
inc
reset_state
write_dispatch "sess-10" "tdd-implementer" "target=docs/" "Update docs"
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-10"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (sentinel mismatch)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 11: dispatch from a different session_id is ignored -> exit 2 ---
echo "Test 11: dispatch from different session is ignored -> exit 2"
inc
reset_state
write_dispatch "sess-other" "tdd-implementer" "target=web/" "Add foo"
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-11"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (cross-session ignored)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 12: session_id from stdin JSON wins over CLAUDE_SESSION_ID env fallback ---
echo "Test 12: stdin session_id wins; env fallback used when stdin omits it"
inc
reset_state
write_dispatch "env-fallback-sess" "tdd-implementer" "target=web/" "Add foo"
# stdin omits session_id; env CLAUDE_SESSION_ID provides it -> dispatch should be found
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"}}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task" CLAUDE_SESSION_ID=env-fallback-sess)
if [ "$RC" = "0" ]; then
  pass_msg "env fallback session_id used when stdin lacks one"
else
  fail_msg "expected exit 0 with env fallback session_id, got $RC"
fi

# Subassertion: stdin session_id takes precedence over env CLAUDE_SESSION_ID
inc
reset_state
write_dispatch "stdin-wins" "tdd-implementer" "target=web/" "Add foo"
# stdin has stdin-wins; env has different value -> should still find dispatch
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"stdin-wins"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task" CLAUDE_SESSION_ID=other-sess)
if [ "$RC" = "0" ]; then pass_msg "stdin session_id wins over env"; else fail_msg "expected exit 0, got $RC"; fi

# --- Test 13: target=. is rejected (trivial sentinel) -> exit 2 ---
echo "Test 13: target=. is rejected -> exit 2"
inc
reset_state
write_dispatch "sess-13" "tdd-implementer" "target=. Attempt global" "Attempt global"
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-13"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (trivial target rejected)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 13a: target=../.. is rejected (parent-traversal-only sentinel) -> exit 2 ---
echo "Test 13a: target=../.. is rejected -> exit 2"
inc
reset_state
write_dispatch "sess-13a" "tdd-implementer" "target=../.. Attempt escape" "Attempt escape"
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-13a"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (parent-traversal target rejected)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 14: target=/ is rejected -> exit 2 ---
echo "Test 14: target=/ is rejected -> exit 2"
inc
reset_state
write_dispatch "sess-14" "tdd-implementer" "target=/ Attempt global" "Attempt global"
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-14"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (absolute-root target rejected)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 15: target=./ normalizes to . and is rejected -> exit 2 ---
echo "Test 15: target=./ normalizes to . and is rejected -> exit 2"
inc
reset_state
write_dispatch "sess-15" "tdd-implementer" "target=./ Attempt global" "Attempt global"
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-15"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (trailing-slash-current-dir rejected)"; else fail_msg "expected exit 2, got $RC"; fi

# --- Test 16: stale cache is swept, fresh cache is written ---
echo "Test 16: stale /tmp cache swept; fresh cache written"
inc
reset_state
# Pre-create a stale cache after reset_state (which just purged /tmp caches).
STALE_CACHE=/tmp/claude-path-c-OTHER-sess-888.cache
printf 'NOT_PATH_C\n0.0\n' > "$STALE_CACHE"
touch -d '25 hours ago' "$STALE_CACHE"
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-16"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
FRESH_CACHE=/tmp/claude-path-c-sess-16-999.cache
SUB_OK=1
if [ "$RC" != "2" ]; then SUB_OK=0; fail_reason="RC was $RC, expected 2"; fi
if [ -f "$STALE_CACHE" ]; then SUB_OK=0; fail_reason="${fail_reason:-}stale cache $STALE_CACHE still present"; fi
if [ ! -f "$FRESH_CACHE" ]; then
  SUB_OK=0; fail_reason="${fail_reason:-}fresh cache $FRESH_CACHE not written"
else
  FIRST_LINE=$(head -n1 "$FRESH_CACHE")
  if [ "$FIRST_LINE" != "PATH_C" ]; then
    SUB_OK=0; fail_reason="${fail_reason:-}fresh cache first line '$FIRST_LINE' != 'PATH_C'"
  fi
fi
if [ "$SUB_OK" = "1" ]; then
  pass_msg "exit 2, stale cache swept, fresh PATH_C cache written"
else
  fail_msg "$fail_reason"
fi
unset fail_reason

# --- Test 17: dispatch log older than LOG_MTIME_WINDOW_SECONDS is skipped -> exit 2 ---
echo "Test 17: stale dispatch log (mtime > 24h ago) skipped -> exit 2"
inc
reset_state
write_dispatch "sess-17" "tdd-implementer" "target=web/" "Add foo"
touch -d '25 hours ago' "$PROJ/.claude/logs/subagents"/*.json
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"web/foo.ts"},"session_id":"sess-17"}'
RC=$(run_hook "$PAYLOAD" CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task")
if [ "$RC" = "2" ]; then pass_msg "exit 2 (stale dispatch skipped by mtime filter)"; else fail_msg "expected exit 2, got $RC"; fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
