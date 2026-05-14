#!/bin/bash
set -euo pipefail

# Asserts $CLAUDE_PROJECT_DIR/.claude/base-branch takes precedence over
# PIPELINE_BASE_BRANCH from pipeline.config in enforce-base-branch.py.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/enforce-base-branch.py"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.claude"
printf 'PIPELINE_BASE_BRANCH="ignore-me"\n' > "$SANDBOX/pipeline.config"
printf 'custom-base\n' > "$SANDBOX/.claude/base-branch"

PASS=0
FAIL=0

run_hook() {
  local cmd_arg="$1"
  local payload
  payload=$(printf '{"tool_input":{"command":"gh pr create --base %s --title t"}}' "$cmd_arg")
  set +e
  echo "$payload" | env -i HOME="$HOME" PATH="/usr/bin:/bin" CLAUDE_PROJECT_DIR="$SANDBOX" \
    python3 "$HOOK" >/dev/null 2>"$SANDBOX/err"
  local rc=$?
  set -e
  echo "$rc"
}

# .claude/base-branch ("custom-base") wins → allow --base custom-base.
RC=$(run_hook "custom-base")
if [ "$RC" = "0" ]; then
  echo "  PASS: --base custom-base allowed when .claude/base-branch=custom-base"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected exit 0, got $RC (stderr: $(cat "$SANDBOX/err"))"
  FAIL=$((FAIL + 1))
fi

# --base ignore-me (the pipeline.config value) should be blocked, because
# .claude/base-branch wins.
RC=$(run_hook "ignore-me")
if [ "$RC" != "0" ] && grep -q 'custom-base' "$SANDBOX/err"; then
  echo "  PASS: --base ignore-me blocked, stderr names 'custom-base'"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected non-zero exit with 'custom-base' in stderr; rc=$RC, stderr: $(cat "$SANDBOX/err")"
  FAIL=$((FAIL + 1))
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
