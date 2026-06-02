#!/bin/bash
set -uo pipefail
#
# Contract test (issue #763): /pipeline:run is now a thin DEPRECATED ALIAS that
# forwards to /pipeline:status. It must delegate to status (not fullsend), carry
# a deprecation notice, and stay short.
#
# Asserts:
#   (a) the alias delegates via Skill(skill: "pipeline:status")
#   (b) the alias carries a deprecation-notice string (renamed to status)
#   (c) the alias body is short (< 40 lines)
#   (d) the alias does NOT delegate to pipeline:fullsend (autonomous advancement
#       is NOT routed through the alias)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALIAS="$REPO_ROOT/skills/run/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$ALIAS" ]; then
  fail_msg "alias skills/run/SKILL.md not found at $ALIAS"
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# (a) Delegates to pipeline:status.
if grep -qF 'Skill(skill: "pipeline:status"' "$ALIAS"; then
  pass_msg "alias delegates via Skill(skill: \"pipeline:status\")"
else
  fail_msg "alias does not delegate via Skill(skill: \"pipeline:status\")"
fi

# (b) Deprecation notice present.
if grep -qiE 'renamed to .*/?pipeline:status|deprecated alias' "$ALIAS"; then
  pass_msg "alias carries a deprecation-notice string"
else
  fail_msg "alias is missing a deprecation-notice string"
fi

# (c) Body is short (< 40 lines).
LINES=$(wc -l < "$ALIAS")
if [ "$LINES" -lt 40 ]; then
  pass_msg "alias body is short ($LINES lines < 40)"
else
  fail_msg "alias body too long ($LINES lines >= 40); the alias must stay thin"
fi

# (d) Does NOT delegate to fullsend.
if grep -qF 'Skill(skill: "pipeline:fullsend"' "$ALIAS"; then
  fail_msg "alias delegates to pipeline:fullsend (must delegate to status only)"
else
  pass_msg "alias does not delegate to pipeline:fullsend"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
