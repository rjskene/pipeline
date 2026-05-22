"""
PreToolUse hook — restricts file operations to the project directory and ~/.claude/.
Exits 2 (blocked) if a tool targets a path outside those boundaries.
"""
import json
import os
import re
import sys
from pathlib import Path

PLUGIN_ROOT = os.environ.get("CLAUDE_PLUGIN_ROOT")
if not PLUGIN_ROOT:
    print(
        "restrict_paths.py: CLAUDE_PLUGIN_ROOT not set in hook env — "
        "cannot resolve plugin paths. Likely a harness env-propagation "
        "regression (see issue #339). Allowing this call (fail-open) so "
        "the assistant can recover. To re-enable path restriction, ensure "
        "CLAUDE_PLUGIN_ROOT is exported in the harness env before "
        "invoking Claude Code.",
        file=sys.stderr,
    )
    sys.exit(0)

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402

data = json.load(sys.stdin)
tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input", {})

PROJECT_DIR = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))
CLAUDE_HOME = os.path.realpath(os.path.expanduser("~/.claude"))

ALLOWED_ROOTS = [PROJECT_DIR, CLAUDE_HOME]

# Also allow worktrees that live outside the project dir (sibling dirs like <prefix>-<N>-*)
_WORKTREE_PREFIX = _read_config("PIPELINE_WORKTREE_PREFIX", "wt", project_dir=PROJECT_DIR)
WORKTREE_PATTERN = re.compile(re.escape(os.path.dirname(PROJECT_DIR)) + r"/" + re.escape(_WORKTREE_PREFIX) + r"-\d+-")

# Protected paths — block Write/Edit to settings and hook files (in project and worktrees)
PROTECTED_PATTERNS = [
    r"\.claude/settings\.json$",
    r"\.claude/settings\.local\.json$",
    r"\.claude/hooks/",
]


def is_protected(path: str) -> bool:
    """Return True if path is a settings or hook file that should not be modified."""
    real = os.path.realpath(path)
    for pattern in PROTECTED_PATTERNS:
        if re.search(pattern, real):
            return True
    return False


def is_allowed(path: str) -> bool:
    if not path:
        return True
    real = os.path.realpath(path)
    for root in ALLOWED_ROOTS:
        if real == root or real.startswith(root + os.sep):
            return True
    if WORKTREE_PATTERN.match(real):
        return True
    return False


def extract_paths() -> list[str]:
    """Extract file paths from tool input based on tool type."""
    paths = []

    if tool_name in ("Read", "Write", "Edit"):
        p = tool_input.get("file_path", "")
        if p:
            paths.append(p)

    elif tool_name in ("Glob", "Grep"):
        p = tool_input.get("path", "")
        if p:
            paths.append(p)

    elif tool_name == "Bash":
        # Best-effort: extract absolute paths from the command string.
        command = tool_input.get("command", "")
        # Pre-scrub env-var literals so unsubstituted ${VAR} / $VAR tokens
        # in the command text can't false-positive the path extractor. Two
        # passes: curly form first (explicit braces), then bare form on the
        # residue. Uppercase + underscore matches conventional env-var
        # naming and avoids consuming shell positional/special params like
        # $1, $?, $@ that can't be paths anyway. See #353.
        scrubbed = re.sub(r"\$\{[A-Z_][A-Z0-9_]*\}", "", command)
        scrubbed = re.sub(r"\$[A-Z_][A-Z0-9_]*", "", scrubbed)
        for m in re.finditer(r'(?:"|\')?(/[^\s"\';<>|&]+)(?:"|\')?', scrubbed):
            candidate = m.group(1)
            # Skip the jq alternative operator (// inside a filter) and any
            # other leading-double-slash substring that isn't a real path
            # root on Linux. See #353.
            if candidate.startswith("//"):
                continue
            if candidate in ("/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr"):
                continue
            if candidate.startswith("/tmp"):
                continue
            # Skip fragments that aren't real paths (e.g. branch names
            # like /rerate-after-edits or commit message fragments like /Reject)
            if not os.path.exists(candidate):
                continue
            paths.append(candidate)

    return paths


paths = extract_paths()

# Check for protected file edits (Write/Edit only)
if tool_name in ("Write", "Edit"):
    for path in paths:
        if is_protected(path):
            print(
                f"BLOCKED: cannot modify protected file: {path}",
                file=sys.stderr,
            )
            sys.exit(2)

# Check for path boundary violations
for path in paths:
    if not is_allowed(path):
        print(
            f"BLOCKED: path outside project boundary: {path}",
            file=sys.stderr,
        )
        sys.exit(2)
