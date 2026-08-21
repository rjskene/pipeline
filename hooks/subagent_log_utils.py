"""
Shared helpers for subagent activity logging.

Provides:
- Log path computation (relative to CLAUDE_PROJECT_DIR)
- Slug sanitization for file names
- Field truncation with byte-count markers
- Per-agent JSON record builder (schema_version 1)
- fcntl-based append locking for the consolidated log
"""
try:
    import fcntl
except ImportError:  # POSIX-only; absent on win32
    fcntl = None
import json
import os
import re
import signal
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Fail-open bounded stdin read
# ---------------------------------------------------------------------------

def read_event_stdin(timeout: int = 5) -> dict:
    """Read+parse the hook event JSON from stdin with a bounded, fail-open
    deadline. Returns {} on timeout, EOF/empty, or malformed JSON — a guard
    hook that cannot read its event must never wedge the session (#917).
    On platforms without SIGALRM (win32), the alarm is skipped and stdin is
    read plainly (fail-open) — Claude Code closes the hook's stdin at event
    end, so the read still terminates (#968)."""
    _has_alarm = hasattr(signal, "SIGALRM") and hasattr(signal, "alarm")

    def _on_timeout(signum, frame):
        raise TimeoutError

    old = None
    try:
        if _has_alarm:
            old = signal.signal(signal.SIGALRM, _on_timeout)
            signal.alarm(timeout)
        raw = sys.stdin.read()
    except Exception:
        return {}
    finally:
        if _has_alarm:
            signal.alarm(0)
            if old is not None:
                signal.signal(signal.SIGALRM, old)
    if not raw or not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except (ValueError, json.JSONDecodeError):
        return {}


# ---------------------------------------------------------------------------
# Log paths
# ---------------------------------------------------------------------------

def _project_dir() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))


def subagents_dir() -> Path:
    """Per-agent JSON files directory: .claude/logs/subagents/"""
    return _project_dir() / ".claude" / "logs" / "subagents"


def consolidated_log_path() -> Path:
    """One-line-per-agent log: .claude/logs/subagents.log"""
    return _project_dir() / ".claude" / "logs" / "subagents.log"


def error_log_path() -> Path:
    """Error log: .claude/logs/subagent-hook-errors.log"""
    return _project_dir() / ".claude" / "logs" / "subagent-hook-errors.log"


# ---------------------------------------------------------------------------
# Slug sanitization
# ---------------------------------------------------------------------------

def sanitize_slug(description: str) -> str:
    """Collapse non-alnum runs to single hyphens, max 60 chars."""
    slug = re.sub(r'[^a-z0-9]+', '-', description.lower()).strip('-')[:60]
    return slug or "no-description"


# ---------------------------------------------------------------------------
# Field truncation
# ---------------------------------------------------------------------------

PROMPT_MAX_CHARS = 4096
RESULT_MAX_CHARS = 8192


def truncate_field(value: str, max_chars: int) -> tuple[str, bool]:
    """Truncate a string at max_chars, appending a byte-count marker.

    Returns (possibly_truncated_string, was_truncated).
    """
    if len(value) <= max_chars:
        return value, False
    original_bytes = len(value.encode("utf-8", errors="replace"))
    marker = f"... [truncated {original_bytes} bytes]"
    return value[:max_chars] + marker, True


# ---------------------------------------------------------------------------
# Leaf result-text extraction (#1233)
# ---------------------------------------------------------------------------

def extract_result_text(tool_response: dict) -> str:
    """Extract the leaf's returned text from a PostToolUse(Agent) tool_response.

    The real payload (status == "completed") carries NO `result` key: the
    leaf's return lives in `tool_response["content"]`, a list of
    {"type": "text", "text": ...} blocks. Join every text block's `text` with
    "\\n"; non-dict / non-text blocks are skipped, never raised on (the hook's
    fail-open contract stays intact).

    If `content` is absent, is not a list, or yields no text blocks (e.g. the
    `status == "async_launched"` background-dispatch shape, which carries
    neither `content` nor `result`), fall back to the legacy
    `tool_response.get("result", "")` shape so old synthetic fixtures and any
    genuinely `result`-keyed payload keep working.
    """
    content = tool_response.get("content")
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text")
                if isinstance(text, str):
                    parts.append(text)
        if parts:
            return "\n".join(parts)
    return tool_response.get("result", "") or ""


# ---------------------------------------------------------------------------
# JSON record builder
# ---------------------------------------------------------------------------

def build_json_record(
    *,
    timestamp_utc: str,
    session_id: str,
    agent_id: str | None,
    description: str,
    subagent_type: str,
    prompt: str,
    result: str,
    usage: dict,
    total_tokens: int,
    total_duration_ms: int,
    num_turns: int,
    jsonl_path_hint: str,
    status: str = "",
) -> dict:
    """Build the per-agent JSON record (schema_version 1).

    `status` (#1233, additive, keyword-only, default "") records the
    PostToolUse(Agent) payload's `status` field so `async_launched`
    (background dispatch — the leaf's result never reaches this hook) is
    mechanically distinguishable from "the leaf returned nothing".
    """
    prompt_truncated_val, prompt_was_truncated = truncate_field(prompt, PROMPT_MAX_CHARS)
    result_truncated_val, result_was_truncated = truncate_field(result, RESULT_MAX_CHARS)

    return {
        "schema_version": 1,
        "timestamp_utc": timestamp_utc,
        "session_id": session_id,
        "agent_id": agent_id,
        "description": description,
        "subagent_type": subagent_type,
        "status": status,
        "prompt": prompt_truncated_val,
        "prompt_truncated": prompt_was_truncated,
        "result": result_truncated_val,
        "result_truncated": result_was_truncated,
        "usage": {
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
            "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0),
        },
        "total_tokens": total_tokens,
        "total_duration_ms": total_duration_ms,
        "num_turns": num_turns,
        "jsonl_path_hint": jsonl_path_hint,
    }


# ---------------------------------------------------------------------------
# fcntl-based append locking
# ---------------------------------------------------------------------------

def append_locked(path: Path, line: str) -> None:
    """Append a line to the given file, using fcntl.flock for atomicity.

    Creates parent directories as needed. On platforms without fcntl (win32),
    falls back to a plain unlocked append — a logging/locking capability gap
    must never wedge a hook (#917/#968).
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    out = line if line.endswith("\n") else line + "\n"
    with open(path, "a") as f:
        if fcntl is not None:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
            try:
                f.write(out)
            finally:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        else:
            # Fail-open: no advisory lock available on this platform (win32).
            f.write(out)
