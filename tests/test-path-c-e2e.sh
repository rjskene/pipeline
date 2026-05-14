#!/bin/bash
set -euo pipefail

# End-to-end test for the PATH C delegation flow:
#   Step A: stub gh -> 'multi-task'; synthesize an Edit hook payload for
#           web/foo.ts in a fresh session; expect exit 2 (blocked).
#   Step B: write a synthetic tdd-implementer dispatch JSON (with a matching
#           target=web/ sentinel) for the same session_id; wipe the label
#           cache; re-run the same Edit; expect exit 0 (allowed).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/enforce-path-c-delegation.py"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$HOOK" ]; then
  echo "ERROR: hook missing at $HOOK" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/logs/subagents" "$PROJ/web"
printf 'PIPELINE_REPO="fake/repo"\n' > "$PROJ/pipeline.config"

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_LABELS:-multi-task}"
EOF
chmod +x "$STUB_DIR/gh"

SESSION_ID="e2e-sess-$$"
ISSUE_NUM="999"

PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
  'tool_name': 'Edit',
  'tool_input': {'file_path': 'web/foo.ts'},
  'session_id': '$SESSION_ID',
}))
")

run_hook() {
  local out_file="$WORKDIR/out.txt"
  local err_file="$WORKDIR/err.txt"
  cd "$PROJ"
  set +e
  echo "$PAYLOAD" | env -i \
    HOME="$HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$PROJ" \
    CLAUDE_PIPELINE_ISSUE_NUMBER="$ISSUE_NUM" \
    STUB_LABELS="multi-task" \
    python3 "$HOOK" >"$out_file" 2>"$err_file"
  local rc=$?
  set -e
  cd - >/dev/null
  echo "$rc"
}

echo "Step A: PATH C session, no dispatch -> blocked"
inc
RC=$(run_hook)
if [ "$RC" = "2" ]; then
  pass_msg "Step A blocked (exit 2)"
else
  fail_msg "Step A expected exit 2, got $RC"
fi

echo "Step B: write tdd-implementer dispatch with target=web/, expect allow"
# Wipe label cache so the second run goes through the fetch path again
python3 -c "
import glob, os
for f in glob.glob('/tmp/claude-path-c-${SESSION_ID}-${ISSUE_NUM}.cache'):
    os.remove(f)
"

# Synthesize a dispatch log JSON
python3 - "$PROJ/.claude/logs/subagents/${SESSION_ID}-dispatch.json" "$SESSION_ID" <<'PY'
import json, sys
file, sess = sys.argv[1:3]
with open(file, "w") as f:
    json.dump({
        "schema_version": 1,
        "timestamp_utc": "2026-04-19T00:00:00",
        "session_id": sess,
        "agent_id": "abc12345-fake",
        "description": "E2E dispatch",
        "subagent_type": "tdd-implementer",
        "prompt": "target=web/\n\nDo the thing.",
    }, f)
PY

inc
RC=$(run_hook)
if [ "$RC" = "0" ]; then
  pass_msg "Step B allowed (exit 0) after dispatch"
else
  fail_msg "Step B expected exit 0, got $RC"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
