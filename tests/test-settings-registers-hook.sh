#!/bin/bash
set -euo pipefail

# Verifies .claude-pipeline/settings.json.template registers the
# enforce-path-c-delegation.py hook under TWO separate PreToolUse entries:
# matcher "Edit" and matcher "Write" (NOT a regex alternation like "Edit|Write").

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../settings.json.template"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

echo "Test 1: settings.json.template is valid JSON"
inc
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TEMPLATE" 2>/dev/null; then
  pass_msg "valid JSON"
else
  fail_msg "settings.json.template is not valid JSON"
fi

echo "Test 2: PreToolUse contains a matcher 'Edit' entry that runs enforce-path-c-delegation.py"
inc
if python3 - "$TEMPLATE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
pre = data.get("hooks", {}).get("PreToolUse", [])
for entry in pre:
    if entry.get("matcher") == "Edit":
        for h in entry.get("hooks", []):
            if "enforce-path-c-delegation.py" in h.get("command", ""):
                sys.exit(0)
sys.exit(1)
PY
then
  pass_msg "Edit entry registers hook"
else
  fail_msg "no PreToolUse 'Edit' entry that runs enforce-path-c-delegation.py"
fi

echo "Test 3: PreToolUse contains a matcher 'Write' entry that runs enforce-path-c-delegation.py"
inc
if python3 - "$TEMPLATE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
pre = data.get("hooks", {}).get("PreToolUse", [])
for entry in pre:
    if entry.get("matcher") == "Write":
        for h in entry.get("hooks", []):
            if "enforce-path-c-delegation.py" in h.get("command", ""):
                sys.exit(0)
sys.exit(1)
PY
then
  pass_msg "Write entry registers hook"
else
  fail_msg "no PreToolUse 'Write' entry that runs enforce-path-c-delegation.py"
fi

echo "Test 4: NO regex-alternation matcher (Edit|Write) is used"
inc
if python3 - "$TEMPLATE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
pre = data.get("hooks", {}).get("PreToolUse", [])
for entry in pre:
    matcher = entry.get("matcher", "")
    if "|" in matcher:
        sys.exit(1)
sys.exit(0)
PY
then
  pass_msg "no alternation matcher present"
else
  fail_msg "found a regex-alternation matcher; plan requires per-tool entries"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
