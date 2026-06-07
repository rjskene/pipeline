"""
PreToolUse hook — blocks destructive deletion commands in the Bash tool.
Exits 1 (blocked) if the command matches a known destructive pattern.
"""
import os
import re
import sys
from pathlib import Path

if os.environ.get("ALLOW_DELETIONS") == "true":
    sys.exit(0)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from subagent_log_utils import read_event_stdin  # noqa: E402

data = read_event_stdin()
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
    r"\btruncate\s+(?:-s|--size=?)\s*0\b",   # truncate -s 0 / -s0 / --size=0 / --size 0
    r"(?:^|;|&&|\|\||\n|\()\s*:\s*>\s*\S",   # ": > file" — colon no-op then truncate-clobber
    r">\|\s*\S",                              # ">| file" — bash forced clobber of an explicit target
    r"\bcp\s+/dev/null\s+\S",                 # cp /dev/null file — overwrite target with empty content
    # dd zeroing: of=<target> combined with a null/zero source OR count=0 (order-independent)
    r"\bdd\b.*\bof=\S+.*(?:if=/dev/(?:null|zero)|count=0)|\bdd\b.*(?:if=/dev/(?:null|zero)|count=0).*\bof=\S+",
]

for pattern in BLOCKED:
    if re.search(pattern, command, re.IGNORECASE):
        print(f"BLOCKED: destructive deletion command detected: {command[:120]}", file=sys.stderr)
        sys.exit(1)
