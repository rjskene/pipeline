"""
PreToolUse hook — blocks destructive deletion commands in the Bash tool.
Exits 1 (blocked) if the command matches a known destructive pattern.
"""
import json
import os
import re
import sys

if os.environ.get("ALLOW_DELETIONS") == "true":
    sys.exit(0)

data = json.load(sys.stdin)
command = data.get("tool_input", {}).get("command", "")

BLOCKED = [
    r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f",   # rm -rf, rm -fr, rm -arf, etc.
    r"\brm\s+-[a-zA-Z]*f[a-zA-Z]*r",
    r"\brm\s+-r\b",                      # rm -r
    r"\brm\s+--recursive",               # rm --recursive
    r"\bgit\s+clean\s+.*-f",             # git clean -f / -fd / -fx
    r"\bgit\s+reset\s+--hard",           # git reset --hard
    r"\brmdir\s+/s",                     # Windows rmdir /s
    r"\bdel\s+/[fsq]",                   # del /f /s /q
    r"\brd\s+/s",                        # rd /s
]

for pattern in BLOCKED:
    if re.search(pattern, command, re.IGNORECASE):
        print(f"BLOCKED: destructive deletion command detected: {command[:120]}", file=sys.stderr)
        sys.exit(1)
