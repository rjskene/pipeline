#!/bin/bash
set -euo pipefail

# Asserts .claude-plugin/plugin.json registers each of the seven expected
# hook entries with a ${CLAUDE_PLUGIN_ROOT}/hooks/<filename> command.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"

python3 - "$MANIFEST" <<'PY'
import json, sys

manifest_path = sys.argv[1]
with open(manifest_path) as f:
    manifest = json.load(f)
hooks = manifest.get("hooks", {})

# (event, matcher, filename)
EXPECTED = [
    ("PreToolUse",  "Bash",  "block_deletions.py"),
    ("PreToolUse",  "Bash",  "enforce-base-branch.py"),
    ("PreToolUse",  "Edit",  "enforce-path-c-delegation.py"),
    ("PreToolUse",  "Write", "enforce-path-c-delegation.py"),
    ("PreToolUse",  "*",     "restrict_paths.py"),
    ("PostToolUse", "*",     "log-tool-use.sh"),
    ("PostToolUse", "Agent", "log_subagent.py"),
]

PASS = 0
FAIL = 0
fails = []

for event, matcher, filename in EXPECTED:
    entries = hooks.get(event, [])
    matched = False
    for entry in entries:
        if entry.get("matcher") != matcher:
            continue
        for cmd_obj in entry.get("hooks", []):
            cmd = cmd_obj.get("command", "")
            if "${CLAUDE_PLUGIN_ROOT}" in cmd and f"/hooks/{filename}" in cmd:
                matched = True
                break
        if matched:
            break
    if matched:
        PASS += 1
        print(f"  PASS: {event}/{matcher}/{filename}")
    else:
        FAIL += 1
        fails.append(f"  FAIL: {event}/{matcher}/{filename} not registered")
        print(fails[-1])

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
PY
