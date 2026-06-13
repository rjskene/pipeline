#!/bin/bash
set -euo pipefail

# Tests for the dogfood SessionStart auto-refresh hook registration (issue #611)
# and the negative-space invariant that the published plugin manifest stays
# clean of any DOGFOOD-ONLY SessionStart entry or dogfood-refresh reference.
#
# NOTE (issue #1038): the published manifest now legitimately carries a
# SessionStart entry — the read-only doctor-on-update version-change detector
# (hooks/doctor-on-update.sh), registered on BOTH UserPromptSubmit and
# SessionStart. That is a PUBLISHED hook, not a dogfood leak. So this test no
# longer forbids a SessionStart entry outright; it forbids dogfood-only
# leakage into it (dogfood-refresh / dev/hooks/ references).
#
# Coverage:
#   1. .claude/settings.json registers a SessionStart hook whose command refers
#      to dev/hooks/dogfood-refresh.sh (dogfood-only).
#   2. The published manifest's SessionStart entry (if present) references ONLY
#      published ${CLAUDE_PLUGIN_ROOT}/hooks/ commands — never a dogfood-only
#      dev/hooks/ command.
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

# 2. The published manifest's SessionStart entry (if any) carries ONLY
#    published ${CLAUDE_PLUGIN_ROOT}/hooks/ commands — no dogfood dev/hooks/.
if [ ! -f "$MANIFEST" ]; then
  fail_msg ".claude-plugin/plugin.json exists"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

if jq -r '.hooks.SessionStart // [] | .[].hooks[]?.command' "$MANIFEST" 2>/dev/null \
     | grep -F -q 'dev/hooks/'; then
  fail_msg "published manifest SessionStart entry references dogfood dev/hooks/"
else
  pass_msg "published manifest SessionStart entry has no dogfood dev/hooks/ leak"
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
