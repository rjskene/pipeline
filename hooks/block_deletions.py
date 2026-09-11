"""
PreToolUse hook — blocks destructive deletion commands in the Bash tool.
Exits 2 (blocked) if the command matches a known destructive pattern.

Issue #1321: verbs are matched in COMMAND-WORD position on masked text
(hooks/command_mask.py) instead of anywhere in the raw string — a verb
sitting only inside a quoted pattern operand, a heredoc body, or a
non-executed grep/awk/sed program is not a command. See command_mask's
module docstring for the masking contract.
"""
import os
import posixpath
import re
import sys
from pathlib import Path

if os.environ.get("ALLOW_DELETIONS") == "true":
    sys.exit(0)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from subagent_log_utils import read_event_stdin  # noqa: E402
from command_mask import mask_command, segments  # noqa: E402

data = read_event_stdin()
command = data.get("tool_input", {}).get("command", "")

# Command-word position: start-of-string, a separator/opener/quote-delimiter,
# a `$(` substitution opener, or a `find -exec`/`-execdir`/`-ok`/`-okdir`
# operand slot — optionally followed by wrapper words (sudo/env/xargs/...),
# NAME=value assignments and their positional arguments (timeout 5, nice -n 5).
_HEAD = (
    r"(?:^|[;&|(\n'\"`{]|\$\(|\s-(?:exec|execdir|ok|okdir)\s)\s*"
    r"(?:(?:sudo|doas|env|nohup|nice|time|timeout|command|exec|builtin|xargs|stdbuf"
    r"|if|then|else|elif|do|while|until|!)\s+"
    r"(?:-\S*\s+|[A-Za-z_]\w*=\S*\s+|\d+(?:\.\d+)?[smhd]?\s+)*)*"
    r"(?:[A-Za-z_]\w*=\S*\s+)*"
)

BLOCKED = [
    _HEAD + r"(?P<hit>rm\s+-[a-zA-Z]*r[a-zA-Z]*f)",   # rm -rf, rm -fr, rm -arf, etc.
    _HEAD + r"(?P<hit>rm\s+-[a-zA-Z]*f[a-zA-Z]*r)",
    _HEAD + r"(?P<hit>rm\s+-r\b)",                      # rm -r
    _HEAD + r"(?P<hit>rm\s+--recursive)",               # rm --recursive
    _HEAD + r"(?P<hit>git\s+clean\s+.*-f)",             # git clean -f / -fd / -fx
    _HEAD + r"(?P<hit>git\s+reset\s+--hard)",           # git reset --hard
    _HEAD + r"(?P<hit>rmdir\s+/s)",                     # Windows rmdir /s
    _HEAD + r"(?P<hit>del\s+/[fsq])",                   # del /f /s /q
    _HEAD + r"(?P<hit>rd\s+/s)",                        # rd /s
    _HEAD + r"(?P<hit>truncate\s+(?:-s|--size=?)\s*0\b)",   # truncate -s 0 / -s0 / --size=0 / --size 0
    r"(?P<hit>>\|\s*\S+)",                              # ">| file" — bash forced clobber of an explicit target
    _HEAD + r"(?P<hit>cp\s+/dev/null\s+\S+)",           # cp /dev/null file — overwrite target with empty content
    # dd zeroing: of=<target> combined with a null/zero source OR count=0 (order-independent)
    _HEAD + r"(?P<hit>dd\b.*\bof=\S+.*(?:if=/dev/(?:null|zero)|count=0))",
    _HEAD + r"(?P<hit>dd\b.*(?:if=/dev/(?:null|zero)|count=0).*\bof=\S+)",
]

_TMP_ROOTS = ["/tmp"] + (
    [posixpath.normpath(os.environ["TMPDIR"])] if os.environ.get("TMPDIR") else []
)


def _is_tmp(t: str) -> bool:
    if re.fullmatch(r"\$\(\s*mktemp\b[^)]*\)", t):
        return True
    if "$" in t or "`" in t or not t.startswith("/"):
        return False
    n = posixpath.normpath(t)
    return any(n.startswith(r + "/") for r in _TMP_ROOTS)


def _rm_targets_all_tmp(command: str, pos: int) -> bool:
    """True iff the `rm` segment owning the match at byte offset `pos` names
    only literal /tmp (or $TMPDIR) paths or literal $(mktemp ...) targets."""
    segs = segments(command)
    if segs is None:
        return False
    chosen = None
    for start, words in segs:
        if start <= pos and (chosen is None or start > chosen[0]):
            chosen = (start, words)
    if chosen is None:
        return False
    words = chosen[1]
    k = next((i for i, w in enumerate(words) if w.strip("\"'").rsplit("/", 1)[-1] == "rm"), None)
    if k is None:
        return False
    targets = [w for w in words[k + 1:] if not w.startswith("-")]
    return bool(targets) and all(_is_tmp(t) for t in targets)


masked = mask_command(command)
for pattern in BLOCKED:
    for m in re.finditer(pattern, masked, re.IGNORECASE):
        hit = m.group("hit")
        if hit.lower().startswith("rm") and _rm_targets_all_tmp(command, m.start("hit")):
            continue
        print(
            f"BLOCKED: destructive deletion command detected (matched: {hit}): {command[:120]}",
            file=sys.stderr,
        )
        sys.exit(2)
