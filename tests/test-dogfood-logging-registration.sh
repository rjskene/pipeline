#!/bin/bash
set -euo pipefail

# Asserts:
#   (a) .claude-plugin/plugin.json `hooks` object does NOT carry a
#       `PostToolUse` key (consumer install ships no log-* hooks).
#   (b) .claude/settings.json `hooks.PostToolUse` registers:
#         - exactly one entry matcher="*"  whose command contains "log-tool-use.sh"
#         - exactly one entry matcher="Agent" whose command contains "log_subagent.py"
#       and each command references ${CLAUDE_PROJECT_DIR}.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
SETTINGS="$REPO_ROOT/.claude/settings.json"

python3 - "$MANIFEST" "$SETTINGS" <<'PY'
import json, sys

manifest_path, settings_path = sys.argv[1], sys.argv[2]

PASS = 0
FAIL = 0
def check(name, ok):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS: {name}")
    else:
        FAIL += 1
        print(f"  FAIL: {name}")

with open(manifest_path) as f:
    manifest = json.load(f)
manifest_hooks = manifest.get("hooks", {})

check(
    "plugin.json hooks.PostToolUse key absent (no consumer-facing log-* hooks)",
    "PostToolUse" not in manifest_hooks,
)

with open(settings_path) as f:
    settings = json.load(f)
settings_post = settings.get("hooks", {}).get("PostToolUse", [])

def count_entries(matcher, filename_substr):
    n = 0
    for entry in settings_post:
        if entry.get("matcher") != matcher:
            continue
        for cmd_obj in entry.get("hooks", []):
            cmd = cmd_obj.get("command", "")
            if filename_substr in cmd and "${CLAUDE_PROJECT_DIR" in cmd:
                n += 1
    return n

check(
    'settings.json PostToolUse has exactly one matcher="*" entry for log-tool-use.sh via ${CLAUDE_PROJECT_DIR}',
    count_entries("*", "log-tool-use.sh") == 1,
)
check(
    'settings.json PostToolUse has exactly one matcher="Agent" entry for log_subagent.py via ${CLAUDE_PROJECT_DIR}',
    count_entries("Agent", "log_subagent.py") == 1,
)

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
PY
