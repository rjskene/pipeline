"""
PreToolUse hook — ensures all PRs target the worktree's configured base
branch.

EXPECTED_BASE is resolved at hook-invocation time by reading
``$CLAUDE_PROJECT_DIR/.claude/base-branch`` (written by
setup-worktree.sh). If that file is missing, empty, or unreadable, the
hook falls back to ``PIPELINE_BASE_BRANCH`` read from
``$CLAUDE_PROJECT_DIR/pipeline.config`` (default ``"main"``). This lets
a worktree cut from ``next`` (or any other non-default base) correctly
gate its own ``gh pr create`` calls.

Strict allowlist: blocks ``gh pr create`` unless it explicitly uses
``--base <EXPECTED_BASE>``.
"""
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402


def _resolve_expected_base() -> str:
    root = Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))
    meta = root / ".claude" / "base-branch"
    try:
        value = meta.read_text().strip()
    except OSError:
        value = ""
    if value:
        return value
    return _read_config("PIPELINE_BASE_BRANCH", "main", project_dir=root)


EXPECTED_BASE = _resolve_expected_base()

data = json.load(sys.stdin)
command = data.get("tool_input", {}).get("command", "")

# Only inspect gh pr create commands
if not re.search(r"\bgh\s+pr\s+create\b", command):
    sys.exit(0)

# Extract the --base value, if any
match = re.search(r"--base[=\s]+(\S+)", command)

if not match:
    print(
        f"BLOCKED: PRs must explicitly use --base {EXPECTED_BASE}. "
        f"Without --base, `gh pr create` defaults to the repo's default branch on GitHub.",
        file=sys.stderr,
    )
    sys.exit(1)

actual_base = match.group(1).strip("'\"")
if actual_base != EXPECTED_BASE:
    print(
        f"BLOCKED: PRs must target '{EXPECTED_BASE}', not '{actual_base}'. "
        f"Use --base {EXPECTED_BASE}.",
        file=sys.stderr,
    )
    sys.exit(1)

sys.exit(0)
