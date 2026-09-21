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
from command_mask import segments, head_index  # noqa: E402
try:  # #1352 fail-open: a partial hook install (e.g. a legacy
    # subtree copy missing this file) must never crash a guard hook.
    from _deny_log import log_denial  # noqa: E402
except ImportError:
    def log_denial(*_args, **_kwargs):  # noqa: E302
        pass


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

# Treat the unexpanded $PIPELINE_BASE_BRANCH token as the configured base
# (#1323). skills/execute-issue-plan/SKILL.md prescribes
# `--base "$PIPELINE_BASE_BRANCH"` — quoted but unexpanded in the command
# TEXT the hook sees. The two token forms are assembled by concatenation on
# purpose: tests/test-plugin-hooks-runtime-config.sh greps this file for the
# braced `${...}` placeholder form (legacy .template-substitution guard) and
# must not misfire on a Python string literal.
_BASE_VAR = "PIPELINE_BASE_BRANCH"


def _basename(word: str) -> str:
    return word.strip("\"'").rsplit("/", 1)[-1]


def _pr_command_kind(words):
    """Return "create" | "edit" | None for a dequoted-words segment whose
    head word (after NAME= assignments / reserved words / wrapper words,
    per command_mask.head_index()) is `gh`, followed by `pr`, followed by
    `create` or `edit`."""
    i = head_index(words)
    if i == -1 or _basename(words[i]) != "gh":
        return None
    if words[i + 1:i + 2] != ["pr"]:
        return None
    if i + 2 >= len(words):
        return None
    sub = words[i + 2]
    return sub if sub in ("create", "edit") else None


def _extract_base(words):
    """Return the --base value from a segment's dequoted words (both
    `--base X` and `--base=X` forms), or None if absent."""
    for j, w in enumerate(words):
        if w == "--base":
            return words[j + 1] if j + 1 < len(words) else None
        if w.startswith("--base="):
            return w[len("--base="):]
    return None


def _decide(kind, actual_base):
    """Return (exit_code, message_or_None) for a matched `gh pr create|edit`
    segment. Preserves the long-standing decision semantics: missing --base
    on `create` is FATAL; a --base mismatch (after resolving the #1323
    $PIPELINE_BASE_BRANCH token) is blocked; `edit` without --base is a
    title/body-only edit and is allowed."""
    if actual_base is None:
        if kind == "create":
            # Without --base, `gh pr create` silently falls back to the
            # repo's default branch on GitHub.
            return 2, (
                f"BLOCKED: PRs must explicitly use --base {EXPECTED_BASE}. "
                f"Without --base, `gh pr create` defaults to the repo's default branch on GitHub."
            )
        return 0, None

    actual_base = actual_base.strip("'\"")

    # If PIPELINE_BASE_BRANCH is unset in the hook's env, the token is
    # equal-by-construction (the shell expands it from the same
    # pipeline.config EXPECTED_BASE was resolved from) and is allowed. If it
    # IS exported, compare THAT value to EXPECTED_BASE — an exported
    # override that disagrees with the config still denies.
    if actual_base in ("$" + _BASE_VAR, "${" + _BASE_VAR + "}"):
        env_value = os.environ.get(_BASE_VAR)
        actual_base = EXPECTED_BASE if env_value is None else env_value

    if actual_base != EXPECTED_BASE:
        subcommand = "gh pr create" if kind == "create" else "gh pr edit"
        return 2, (
            f"BLOCKED: `{subcommand}` must target '{EXPECTED_BASE}', not '{actual_base}'. "
            f"Use --base {EXPECTED_BASE}."
        )
    return 0, None


def _legacy_scan(command: str, tool_name: str = "Bash", session_id=None) -> int:
    """Pre-#1327 whole-text scan — used ONLY when segments() cannot parse
    the command (unterminated quote). Fail closed: never fewer blocks than
    before #1327."""
    is_create = bool(re.search(r"\bgh\s+pr\s+create\b", command))
    is_edit = bool(re.search(r"\bgh\s+pr\s+edit\b", command))
    if not (is_create or is_edit):
        return 0

    match = re.search(r"--base[=\s]+(\S+)", command)
    actual_base = match.group(1) if match else None
    kind = "create" if is_create else "edit"

    rc, message = _decide(kind, actual_base)
    if message:
        print(message, file=sys.stderr)
    if rc != 0:
        log_denial("enforce-base-branch", tool_name, message or "", command,
                    session_id=session_id)
    return rc


def main() -> int:
    data = read_event_stdin()
    command = data.get("tool_input", {}).get("command", "")
    if not command:
        return 0

    tool_name = data.get("tool_name", "Bash")
    session_id = data.get("session_id")

    segs = segments(command)
    if segs is None:
        return _legacy_scan(command, tool_name=tool_name, session_id=session_id)

    for _, words in segs:
        kind = _pr_command_kind(words)
        if kind is None:
            continue
        rc, message = _decide(kind, _extract_base(words))
        if rc != 0:
            if message:
                print(message, file=sys.stderr)
            log_denial("enforce-base-branch", tool_name, message or "", command,
                        session_id=session_id)
            return rc

    return 0


if __name__ == "__main__":
    sys.exit(main())
