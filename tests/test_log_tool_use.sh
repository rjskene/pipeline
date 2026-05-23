#!/bin/bash
set -euo pipefail
# Test: log-tool-use.sh produces TSV with session= and ISO 8601 timestamp for all 7 tool types.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/log-tool-use.sh"
tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
export CLAUDE_PROJECT_DIR="$tmpdir" CLAUDE_SESSION_ID="test-sess-42"

TOOLS=(
  '{"tool_name":"Write","session_id":"s1","tool_input":{"file_path":"/tmp/f.txt"}}'
  '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/e.txt"}}'
  '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  '{"tool_name":"Read","tool_input":{"file_path":"/tmp/r.txt"}}'
  '{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"src/"}}'
  '{"tool_name":"Agent","tool_input":{"description":"do stuff"}}'
  '{"tool_name":"Skill","tool_input":{"skill":"commit"}}'
)
for t in "${TOOLS[@]}"; do echo "$t" | bash "$HOOK"; done

LOG="$tmpdir/.claude/logs/tool-use.log"; FAIL=0
while IFS= read -r line; do
  echo "$line" | grep -qP '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\t' || { echo "FAIL: no ISO ts: $line"; FAIL=1; }
  echo "$line" | grep -q 'session=' || { echo "FAIL: no session=: $line"; FAIL=1; }
done < "$LOG"

LINES=$(wc -l < "$LOG")
[ "$LINES" -eq 7 ] || { echo "FAIL: expected 7 lines, got $LINES"; FAIL=1; }
grep -q 'session=s1' "$LOG" || { echo "FAIL: JSON session_id not used"; FAIL=1; }
grep -qP 'Bash\tsession=test-sess-42' "$LOG" || { echo "FAIL: env fallback not used"; FAIL=1; }

# --- jq-missing subtest (issue #412): hook must never block tool execution
# when jq is absent from PATH; instead emit a breadcrumb to hook-errors.log
# and skip writing the row.
tmpdir2=$(mktemp -d)
sandbox=$(mktemp -d)
trap 'rm -rf "$tmpdir" "$tmpdir2" "$sandbox"' EXIT

for bin in cat date mkdir tr; do
  src=$(command -v "$bin") || { echo "FAIL: $bin not available to build sandbox"; FAIL=1; }
  [ -n "$src" ] && ln -s "$src" "$sandbox/$bin"
done

# Sanity: jq must NOT be reachable via the sandbox PATH (precondition for the
# whole subtest — otherwise we'd be re-asserting the happy path).
if PATH="$sandbox" command -v jq >/dev/null 2>&1; then
  echo "FAIL: sandbox unexpectedly has jq on PATH; subtest can't exercise the guard"
  FAIL=1
fi

BASH_BIN=$(command -v bash)
set +e
CLAUDE_PROJECT_DIR="$tmpdir2" CLAUDE_SESSION_ID="test-sess-jq-missing" \
  PATH="$sandbox" "$BASH_BIN" "$HOOK" \
  <<<'{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
HOOK_RC=$?
set -e
[ "$HOOK_RC" -eq 0 ] || { echo "FAIL: hook exited $HOOK_RC with jq missing (expected 0)"; FAIL=1; }

LOG2="$tmpdir2/.claude/logs/tool-use.log"
if [ -s "$LOG2" ]; then
  echo "FAIL: tool-use.log was written when jq missing: $(cat "$LOG2")"
  FAIL=1
fi

ERRLOG="$tmpdir2/.claude/logs/hook-errors.log"
[ -f "$ERRLOG" ] || { echo "FAIL: hook-errors.log not created when jq missing"; FAIL=1; }
grep -q 'log-tool-use.sh: jq not found on PATH' "$ERRLOG" 2>/dev/null \
  || { echo "FAIL: hook-errors.log missing 'jq not found on PATH' breadcrumb"; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
