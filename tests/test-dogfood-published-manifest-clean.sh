#!/bin/bash
set -euo pipefail

# Tests for the dogfood SessionStart auto-refresh hook registration (issue #611)
# and the negative-space invariant that the published plugin manifest stays
# clean of any SessionStart entry or dogfood-refresh reference.
#
# Coverage:
#   1. .claude/settings.json registers a SessionStart hook whose command refers
#      to dev/hooks/dogfood-refresh.sh (dogfood-only).
#   2. .claude-plugin/plugin.json has NO SessionStart entry (published manifest
#      stays minimal).
#   3. .claude-plugin/plugin.json does NOT reference dogfood-refresh or
#      dev/hooks/ (no dogfood leakage into the published plugin).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS="$REPO_ROOT/.claude/settings.json"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# 1. .claude/settings.json SessionStart references dev/hooks/dogfood-refresh.sh.
if [ ! -f "$SETTINGS" ]; then
  fail_msg ".claude/settings.json exists"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

if jq -r '.hooks.SessionStart // [] | .[].hooks[]?.command' "$SETTINGS" 2>/dev/null \
     | grep -F -q 'dev/hooks/dogfood-refresh.sh'; then
  pass_msg ".claude/settings.json registers SessionStart -> dev/hooks/dogfood-refresh.sh"
else
  fail_msg ".claude/settings.json registers SessionStart -> dev/hooks/dogfood-refresh.sh"
fi

# 2. .claude-plugin/plugin.json has NO SessionStart entry.
if [ ! -f "$MANIFEST" ]; then
  fail_msg ".claude-plugin/plugin.json exists"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

if jq -e '.hooks.SessionStart // empty' "$MANIFEST" >/dev/null 2>&1; then
  fail_msg ".claude-plugin/plugin.json has NO SessionStart entry"
else
  pass_msg ".claude-plugin/plugin.json has NO SessionStart entry"
fi

# 3. .claude-plugin/plugin.json does NOT reference dogfood-refresh or dev/hooks/.
if grep -F -q 'dogfood-refresh' "$MANIFEST"; then
  fail_msg ".claude-plugin/plugin.json does NOT reference dogfood-refresh"
else
  pass_msg ".claude-plugin/plugin.json does NOT reference dogfood-refresh"
fi

if grep -F -q 'dev/hooks/' "$MANIFEST"; then
  fail_msg ".claude-plugin/plugin.json does NOT reference dev/hooks/"
else
  pass_msg ".claude-plugin/plugin.json does NOT reference dev/hooks/"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
