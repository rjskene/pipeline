"""
Dual-mode hook for pipeline skill gating and superpowers tracking.

Mode is determined by the tool_name field in the stdin JSON:
  - tool_name == "Skill"  → PostToolUse tracking mode
  - tool_name != "Skill"  → PreToolUse gating mode

PostToolUse tracking mode:
  When a pipeline skill (e.g. plan-issue, execute-issue-plan) is invoked via
  the Skill tool, this hook activates a gate requiring the skill's configured
  superpowers to be loaded before codebase tools (Read, Write, Edit, Bash,
  Grep, Glob) are used. It also tracks when superpowers skills are invoked and
  clears the gate once all required superpowers are satisfied.

PreToolUse gating mode:
  Before any codebase tool runs, checks whether an active gate exists. If a
  pipeline skill was invoked but its required superpowers have not all been
  loaded yet, the tool call is blocked with a descriptive message.

Configuration is read from .claude/pipeline-config.json (skill_gates mapping).
State is persisted to .claude/state/skill-gate.json across tool calls.

Always fails open (exit 0) on unexpected errors -- never crash-blocks.
"""
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

TTL_SECONDS = 14400  # 4 hours

project_dir = Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))
config_path = project_dir / ".claude" / "pipeline-config.json"
state_path = project_dir / ".claude" / "state" / "skill-gate.json"
warn_log_path = project_dir / ".claude" / "logs" / "skill-gate-warnings.log"


def load_config() -> dict | None:
    """Load pipeline-config.json. Returns None if missing or invalid."""
    if not config_path.exists():
        return None
    try:
        with open(config_path) as f:
            return json.load(f)
    except Exception:
        return None


def load_state() -> dict | None:
    """Load skill-gate.json state file. Returns None if missing."""
    if not state_path.exists():
        return None
    try:
        with open(state_path) as f:
            return json.load(f)
    except Exception:
        # Invalid JSON -- delete and fail open
        try:
            state_path.unlink(missing_ok=True)
        except Exception:
            pass
        return None


def save_state(state: dict) -> None:
    """Persist state to skill-gate.json, creating parent dirs as needed."""
    state_path.parent.mkdir(parents=True, exist_ok=True)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)


def delete_state() -> None:
    """Remove the state file (stale, different session, etc.)."""
    try:
        state_path.unlink(missing_ok=True)
    except Exception:
        pass


def log_warning(message: str) -> None:
    """Append a timestamped warning to the skill-gate-warnings log."""
    try:
        warn_log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().isoformat(timespec="seconds")
        with open(warn_log_path, "a") as f:
            f.write(f"{ts} | WARNING | {message}\n")
    except Exception:
        pass


def current_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def is_state_expired(state: dict) -> bool:
    """Return True if activated_at is older than TTL_SECONDS."""
    try:
        activated_at = state.get("activated_at", "")
        if not activated_at:
            return True
        dt = datetime.fromisoformat(activated_at)
        # Treat naive datetimes as UTC for consistency
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        now = datetime.now(timezone.utc)
        elapsed = (now - dt).total_seconds()
        return elapsed > TTL_SECONDS
    except Exception:
        return True


def is_different_session(state: dict) -> bool:
    """Return True if the current session differs from the stored one."""
    stored_session = state.get("session_id", "unknown")
    if stored_session == "unknown":
        return False
    current_session = os.environ.get("CLAUDE_SESSION_ID", "unknown")
    if current_session == "unknown":
        return False
    return current_session != stored_session


# ---------------------------------------------------------------------------
# PostToolUse tracking mode
# ---------------------------------------------------------------------------

def handle_post_tool_use(data: dict) -> None:
    """Track Skill invocations to activate gates and record satisfied superpowers."""
    tool_input = data.get("tool_input")

    if tool_input is None:
        log_warning("PostToolUse Skill event received with missing/null tool_input")
        sys.exit(0)

    skill_name = tool_input.get("skill")
    if not skill_name:
        sys.exit(0)

    config = load_config()
    if config is None:
        sys.exit(0)

    skill_gates = config.get("skill_gates", {})

    if skill_name in skill_gates:
        # Activate the gate for this pipeline skill
        required = skill_gates[skill_name]
        session_id = os.environ.get("CLAUDE_SESSION_ID", "unknown")
        state = {
            "active_skill": skill_name,
            "required": required,
            "satisfied": [],
            "activated_at": current_timestamp(),
            "session_id": session_id,
        }
        try:
            save_state(state)
        except Exception as e:
            log_warning(f"Failed to save gate state for {skill_name}: {e}")
        sys.exit(0)

    if skill_name.startswith("superpowers:"):
        # Check if there is an active gate to update
        state = load_state()
        if state is None or not state.get("active_skill"):
            sys.exit(0)

        satisfied = state.get("satisfied", [])
        if skill_name not in satisfied:
            satisfied.append(skill_name)
            state["satisfied"] = satisfied

        # Check if all required are now satisfied
        required = state.get("required", [])
        if all(r in satisfied for r in required):
            state["active_skill"] = None

        try:
            save_state(state)
        except Exception as e:
            log_warning(f"Failed to update gate state for {skill_name}: {e}")

    sys.exit(0)


# ---------------------------------------------------------------------------
# PreToolUse gating mode
# ---------------------------------------------------------------------------

def handle_pre_tool_use(data: dict) -> None:
    """Block codebase tools when a pipeline skill's required superpowers are unmet."""
    tool_name = data.get("tool_name", "")

    state = load_state()
    if state is None:
        sys.exit(0)

    # Invalid JSON was already handled in load_state (returns None + deletes file)

    # TTL check
    if is_state_expired(state):
        delete_state()
        sys.exit(0)

    # Session check
    if is_different_session(state):
        delete_state()
        sys.exit(0)

    active_skill = state.get("active_skill")
    if not active_skill:
        sys.exit(0)

    required = state.get("required", [])
    satisfied = state.get("satisfied", [])

    missing = [r for r in required if r not in satisfied]
    if not missing:
        sys.exit(0)

    # Gate not cleared -- block the tool
    print(
        f"BLOCKED: Pipeline skill '{active_skill}' requires loading superpowers "
        f"{missing} before using {tool_name}. Invoke them via the Skill tool first.",
        file=sys.stderr,
    )
    sys.exit(2)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

try:
    data = json.load(sys.stdin)
    tool_name = data.get("tool_name", "")

    if tool_name == "Skill":
        handle_post_tool_use(data)
    else:
        handle_pre_tool_use(data)

except SystemExit:
    raise
except Exception:
    # Fail open on any unexpected error -- never crash-blocks
    sys.exit(0)
