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
``--base <EXPECTED_BASE>``. Also blocks ``gh pr edit --base <X>`` when
``X`` differs from ``EXPECTED_BASE`` (defense-in-depth against
post-creation retargeting); ``gh pr edit`` without ``--base`` is
unaffected because it represents a title/body-only edit.
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402
from subagent_log_utils import read_event_stdin  # noqa: E402


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

data = read_event_stdin()
command = data.get("tool_input", {}).get("command", "")

# Only inspect `gh pr create` and `gh pr edit` commands; everything
# else passes through untouched.
is_create = bool(re.search(r"\bgh\s+pr\s+create\b", command))
is_edit = bool(re.search(r"\bgh\s+pr\s+edit\b", command))
if not (is_create or is_edit):
    sys.exit(0)

# Extract the --base value, if any (same regex for both arms).
match = re.search(r"--base[=\s]+(\S+)", command)

if not match:
    if is_create:
        # Preserves the long-standing fatal-missing-base semantics:
        # without --base, `gh pr create` silently falls back to the
        # repo's default branch on GitHub.
        print(
            f"BLOCKED: PRs must explicitly use --base {EXPECTED_BASE}. "
            f"Without --base, `gh pr create` defaults to the repo's default branch on GitHub.",
            file=sys.stderr,
        )
        sys.exit(1)
    # is_edit: title/body-only edits omit --base and are allowed.
    sys.exit(0)

actual_base = match.group(1).strip("'\"")
if actual_base != EXPECTED_BASE:
    subcommand = "gh pr create" if is_create else "gh pr edit"
    print(
        f"BLOCKED: `{subcommand}` must target '{EXPECTED_BASE}', not '{actual_base}'. "
        f"Use --base {EXPECTED_BASE}.",
        file=sys.stderr,
    )
    sys.exit(1)

sys.exit(0)
