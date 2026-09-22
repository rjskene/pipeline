"""Shared fail-open helper: log a guard-hook denial to
$CLAUDE_PROJECT_DIR/.claude/logs/hook-denials.jsonl (issue #1352).

Every guard hook that denies (exit 2 / return 2) calls `log_denial(...)`
immediately before its exit, so PreToolUse (and the Stop-hook `enforce-ci-wait`)
denials — otherwise invisible, since `.claude/logs/tool-use.log` is written by
a PostToolUse hook that never fires for a denied call — leave an audit trail.
See docs/observability.md.

Gated on PIPELINE_LOGS_ENABLED (process env wins when set, else
hooks/_pipeline_config.py against $CLAUDE_PROJECT_DIR/pipeline.config);
disabled by default, so this is a no-op that touches no disk unless a host
has opted in.

Public API: log_denial(hook, tool_name, reason, command_text="").
The whole body is wrapped in one try/except Exception: pass — a
denial-logging failure must never turn a deny into a crash or an allow, and
must never itself write an error log (that could cascade a second write
attempt onto the same broken path).
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _pipeline_config import read as _read_config  # noqa: E402
from command_mask import mask_command  # noqa: E402
from subagent_log_utils import append_locked  # noqa: E402

_MAX_COMMAND_LEN = 512


def _resolve_log_dir(project_dir: str) -> Path:
    """Main checkout root for project_dir (issue #1380): git-common-dir's
    parent, same idiom as check-capability-refusal.sh --resolve-sources.
    Falls back to project_dir on any failure — must never raise."""
    try:
        out = subprocess.run(
            ["git", "-C", project_dir, "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip():
            common = Path(out.stdout.strip())
            if not common.is_absolute():
                common = Path(project_dir) / common
            return common.resolve().parent
    except Exception:
        pass
    return Path(project_dir)


def _logs_enabled(project_dir: str) -> bool:
    env_value = os.environ.get("PIPELINE_LOGS_ENABLED")
    if env_value is not None:
        value = env_value
    else:
        value = _read_config("PIPELINE_LOGS_ENABLED", "", project_dir=project_dir)
    return value == "true"


def log_denial(hook: str, tool_name: str, reason: str, command_text: str = "",
                session_id: str = None) -> None:
    """Append one JSONL denial record. Fail-open: swallows every exception.

    `hook` is the denying hook's file stem (e.g. "restrict_paths"),
    `tool_name` the payload's tool_name ("Stop" for enforce-ci-wait),
    `reason` the same stderr text the hook already prints (only its first
    line is recorded), and `command_text` the offending Bash command (masked
    via hooks/command_mask.py before truncation) or, for non-Bash callers,
    the offending file path (masking is a no-op on a bare path).

    `session_id`, when a caller has already resolved one from the event
    payload, takes precedence; otherwise falls back to CLAUDE_SESSION_ID,
    then "unknown".
    """
    try:
        project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
        if not _logs_enabled(project_dir):
            return

        session = session_id or os.environ.get("CLAUDE_SESSION_ID", "unknown")
        first_line = reason.splitlines()[0] if reason else ""
        masked = mask_command(command_text) if command_text else ""

        record = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "hook": hook,
            "tool": tool_name,
            "session": session,
            "reason": first_line,
            "command": masked[:_MAX_COMMAND_LEN],
        }
        log_path = _resolve_log_dir(project_dir) / ".claude" / "logs" / "hook-denials.jsonl"
        append_locked(log_path, json.dumps(record))
    except Exception:
        pass
