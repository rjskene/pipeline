#!/bin/bash
set -euo pipefail

# Asserts both consumer-installed (.claude/hooks/) and plugin-rooted
# hook copies fire idempotently during the Phase 2 transition.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.claude/hooks" "$SANDBOX/.claude/logs"
printf 'PIPELINE_BASE_BRANCH="staging"\n' > "$SANDBOX/pipeline.config"

# Stand up a consumer copy of log-tool-use.sh + enforce-base-branch.py
# (the simulated subtree-install).
cp "$REPO_ROOT/hooks/log-tool-use.sh" "$SANDBOX/.claude/hooks/log-tool-use.sh"
cp "$REPO_ROOT/hooks/_pipeline_config.py" "$SANDBOX/.claude/hooks/_pipeline_config.py"
cp "$REPO_ROOT/hooks/enforce-base-branch.py" "$SANDBOX/.claude/hooks/enforce-base-branch.py"
chmod +x "$SANDBOX/.claude/hooks/log-tool-use.sh"

PASS=0
FAIL=0

LOG_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"sess-1"}'

# Fire log-tool-use.sh from both consumer and plugin paths.
for hook in "$SANDBOX/.claude/hooks/log-tool-use.sh" "$REPO_ROOT/hooks/log-tool-use.sh"; do
  if echo "$LOG_PAYLOAD" | CLAUDE_PROJECT_DIR="$SANDBOX" bash "$hook" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $hook returned non-zero"
  fi
done

LOG_FILE="$SANDBOX/.claude/logs/tool-use.log"
if [ -f "$LOG_FILE" ]; then
  LINES=$(wc -l < "$LOG_FILE")
  if [ "$LINES" -ge 2 ]; then
    echo "  PASS: tool-use.log has $LINES lines after both fires"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: tool-use.log only has $LINES line(s); expected >= 2"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL: $LOG_FILE not created"
  FAIL=$((FAIL + 1))
fi

# Fire enforce-base-branch.py from both copies — both should exit 0
# for a valid --base staging input (idempotent gate).
PR_PAYLOAD='{"tool_input":{"command":"gh pr create --base staging --title t"}}'
for hook in "$SANDBOX/.claude/hooks/enforce-base-branch.py" "$REPO_ROOT/hooks/enforce-base-branch.py"; do
  if echo "$PR_PAYLOAD" | CLAUDE_PROJECT_DIR="$SANDBOX" python3 "$hook" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $hook rejected --base staging"
  fi
done

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
