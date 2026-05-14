"""
PostToolUse hook — logs Agent tool invocations to per-agent JSON files
and a consolidated tab-separated log.

Fires on tool_name == "Agent". Writes:
  1. Per-agent JSON: .claude/logs/subagents/<YYYYMMDD-HHMMSS>_<slug>_<agentIdShort>.json
  2. Consolidated line: .claude/logs/subagents.log

Fail-open: any exception logs to .claude/logs/subagent-hook-errors.log
and exits 0 — never blocks the Agent tool call.
"""
import json
import os
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path

# Import shared helpers (same directory)
sys.path.insert(0, str(Path(__file__).resolve().parent))
from subagent_log_utils import (
    append_locked,
    build_json_record,
    consolidated_log_path,
    error_log_path,
    sanitize_slug,
    subagents_dir,
)


def log_error(message: str) -> None:
    """Best-effort error logging — swallows its own exceptions."""
    try:
        err_path = error_log_path()
        err_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
        with open(err_path, "a") as f:
            f.write(f"{ts} | ERROR | {message}\n")
    except Exception:
        pass


try:
    data = json.load(sys.stdin)
    tool_name = data.get("tool_name", "")

    # Only handle Agent tool invocations
    if tool_name != "Agent":
        sys.exit(0)

    tool_input = data.get("tool_input") or {}
    # Support both tool_response and tool_result field names
    tool_response = data.get("tool_response") or data.get("tool_result") or {}

    # Extract fields
    now = datetime.now(timezone.utc)
    timestamp_utc = now.isoformat(timespec="seconds")
    session_id = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", "unknown")

    description = tool_input.get("description", "")
    subagent_type = tool_input.get("subagent_type", "general-purpose")
    prompt = tool_input.get("prompt", "")

    result = tool_response.get("result", "")
    usage = tool_response.get("usage") or {}
    total_tokens = tool_response.get("total_tokens", 0)
    total_duration_ms = tool_response.get("total_duration_ms", 0)
    num_turns = tool_response.get("num_turns", 0)

    agent_id = tool_response.get("agentId")
    agent_id_short = agent_id[:8] if agent_id else "unknown"

    slug = sanitize_slug(description) if description else "no-description"

    # Build jsonl_path_hint
    uid = os.getuid()
    jsonl_path_hint = f"/tmp/claude-{uid}/{slug}/{session_id}/tasks/{agent_id}.output" if agent_id else ""

    # 1. Write per-agent JSON file
    file_ts = now.strftime("%Y%m%d-%H%M%S-%f")
    filename = f"{file_ts}_{slug}_{agent_id_short}.json"
    json_dir = subagents_dir()
    json_dir.mkdir(parents=True, exist_ok=True)
    json_path = json_dir / filename

    record = build_json_record(
        timestamp_utc=timestamp_utc,
        session_id=session_id,
        agent_id=agent_id,
        description=description,
        subagent_type=subagent_type,
        prompt=prompt,
        result=result,
        usage=usage,
        total_tokens=total_tokens,
        total_duration_ms=total_duration_ms,
        num_turns=num_turns,
        jsonl_path_hint=jsonl_path_hint,
    )

    with open(json_path, "w") as f:
        json.dump(record, f, indent=2)

    # 2. Append to consolidated log (tab-separated)
    result_chars = len(result)
    safe_description = description.replace("\t", " ").replace("\n", " ")
    consolidated_line = "\t".join([
        timestamp_utc,
        session_id,
        safe_description,
        str(result_chars),
        str(total_tokens),
        str(total_duration_ms),
        filename,
    ])
    append_locked(consolidated_log_path(), consolidated_line)

    sys.exit(0)

except SystemExit:
    raise
except Exception:
    # Fail open — log the error and exit cleanly
    try:
        log_error(traceback.format_exc())
    except Exception:
        pass
    sys.exit(0)
