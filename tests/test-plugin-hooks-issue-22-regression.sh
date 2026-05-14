#!/bin/bash
set -euo pipefail

# Regression test for the failure mode tracked under (formerly) issue #22:
# manifest-registered hooks must fire correctly with ZERO consumer setup
# beyond a pipeline.config. No .claude/settings.json, no .claude/hooks/.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
printf 'PIPELINE_BASE_BRANCH="staging"\n' > "$SANDBOX/pipeline.config"

PASS=0
FAIL=0

# 1. Every manifest hook command resolves to a real file under the plugin root.
python3 - "$MANIFEST" "$REPO_ROOT" <<'PY' || exit 1
import json, os, sys, shlex
manifest_path, repo_root = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    m = json.load(f)
hooks = m.get("hooks", {})
bad = []
for event in ("PreToolUse", "PostToolUse"):
    for entry in hooks.get(event, []):
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            resolved = cmd.replace("${CLAUDE_PLUGIN_ROOT}", repo_root)
            parts = shlex.split(resolved)
            if len(parts) < 2:
                bad.append(f"unparseable command: {cmd}")
                continue
            script_path = parts[1]
            if not os.path.isfile(script_path):
                bad.append(f"missing script: {script_path} (from {cmd})")
if bad:
    print("  FAIL: unresolved manifest hook commands:")
    for b in bad:
        print(f"    {b}")
    sys.exit(1)
print(f"  PASS: all manifest hook commands resolve to real files")
PY
PASS=$((PASS + 1))

# 2. log-tool-use.sh runs end-to-end from plugin root with CLAUDE_PROJECT_DIR
# pointing at the sandbox; writes to $SANDBOX/.claude/logs/tool-use.log.
LOG_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"regress-sess"}'
if echo "$LOG_PAYLOAD" | CLAUDE_PROJECT_DIR="$SANDBOX" bash "$REPO_ROOT/hooks/log-tool-use.sh" >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  echo "  FAIL: log-tool-use.sh returned non-zero from plugin root"
  FAIL=$((FAIL + 1))
fi

if [ -f "$SANDBOX/.claude/logs/tool-use.log" ]; then
  echo "  PASS: log written under \$SANDBOX/.claude/logs/"
  PASS=$((PASS + 1))
else
  echo "  FAIL: $SANDBOX/.claude/logs/tool-use.log not created"
  FAIL=$((FAIL + 1))
fi

# 3. enforce-base-branch.py runs end-to-end with no consumer .claude/.
PR_PAYLOAD='{"tool_input":{"command":"gh pr create --base staging --title t"}}'
if echo "$PR_PAYLOAD" | CLAUDE_PROJECT_DIR="$SANDBOX" python3 "$REPO_ROOT/hooks/enforce-base-branch.py" >/dev/null 2>&1; then
  echo "  PASS: enforce-base-branch.py fires from plugin root"
  PASS=$((PASS + 1))
else
  echo "  FAIL: enforce-base-branch.py failed from plugin root"
  FAIL=$((FAIL + 1))
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
