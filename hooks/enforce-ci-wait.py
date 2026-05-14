"""Stop hook — enforces CI-wait discipline on evaluate-issue-pr sessions.

Reads .claude/logs/tool-use.log (filtered by session_id) and asserts that the
prescribed `gh pr view ... statusCheckRollup -> gh pr checks ... --watch ->
gh pr view ... statusCheckRollup` sequence was actually executed before the
agent attempts to Stop. An Approved verdict with a failing final rollup is
also blocked.

Fail-open: any uncaught error logs to .claude/logs/enforce-ci-wait-errors.log
and exits 0. A hook bug must never brick evaluate-issue-pr.

Exit codes:
  0 = allow (default)
  2 = block (Claude Code hook contract; surfaces stderr to the model)
"""
import json
import os
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402


def project_dir() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))


def error_log_path() -> Path:
    return project_dir() / ".claude" / "logs" / "enforce-ci-wait-errors.log"


def log_error(message: str) -> None:
    try:
        path = error_log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} | {message}\n")
    except Exception:
        pass


def main() -> int:
    if os.environ.get("CLAUDE_PIPELINE_SKILL", "") != "evaluate-issue-pr":
        return 0
    raw = sys.stdin.read()
    try:
        json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return 0
    return 0


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception:
    log_error(traceback.format_exc())
    sys.exit(0)
