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

[ "$FAIL" -eq 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
