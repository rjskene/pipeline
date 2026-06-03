"""
PreToolUse hook — enforces SDD delegation on PATH C (multi-task) pipeline issues.

Blocks Edit/Write from the orchestrator session unless a tdd-implementer
subagent has been dispatched for the file's directory (via a `target=<dir>`
sentinel in the subagent prompt or description).

Fail-open semantics: any uncaught error logs to
.claude/logs/enforce-path-c-errors.log and exits 0. The hook is an advisory
guardrail; a hook bug must never brick the pipeline.

Exit codes:
  0 = allow (default)
  2 = block (Claude Code hook contract; surfaces stderr to the model)
"""
import json
import os
import re
import subprocess
import sys
import time
import traceback
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402
from subagent_log_utils import read_event_stdin  # noqa: E402


def _pipeline_repo() -> str:
    return _read_config("PIPELINE_REPO", "")

LABEL_CACHE_TTL_SECONDS = 300
GH_TIMEOUT_SECONDS = 5
CACHE_TTL_SECONDS = 24 * 60 * 60
LOG_MTIME_WINDOW_SECONDS = 24 * 60 * 60

# Allowlist patterns (case-insensitive). Files matching any of these can be
# edited directly by the orchestrator with no subagent dispatch.
ALLOWLIST_PATTERNS = [
    re.compile(r"\.(test|spec)\.[a-z0-9]+$", re.IGNORECASE),
    re.compile(r"(^|/)(tests?|__tests__)/", re.IGNORECASE),
    re.compile(r"(^|/)test_[^/]+\.py$", re.IGNORECASE),
    re.compile(r"_test\.[a-z0-9]+$", re.IGNORECASE),
    re.compile(r"\.(md|txt|yml|yaml|toml|lock|json)$", re.IGNORECASE),
    re.compile(r"(^|/)CHANGELOG", re.IGNORECASE),
    re.compile(r"(^|/)\.github/"),
    re.compile(r"(^|/)\.claude/logs/"),
    re.compile(r"^/tmp/"),
]

SENTINEL_RE = re.compile(r"(?:^|\s)target=([^\s]+?)/?(?=\s|$)")


def project_dir() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))


def error_log_path() -> Path:
    return project_dir() / ".claude" / "logs" / "enforce-path-c-errors.log"


def log_error(message: str) -> None:
    """Best-effort error logging — swallows its own exceptions."""
    try:
        path = error_log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} | {message}\n")
    except Exception:
        pass


def is_allowlisted(file_path: str) -> bool:
    return any(p.search(file_path) for p in ALLOWLIST_PATTERNS)


def label_cache_path(session_id: str, issue_number: str) -> Path:
    return Path("/tmp") / f"claude-path-c-{session_id}-{issue_number}.cache"


def sweep_stale_caches() -> None:
    """Best-effort deletion of /tmp/claude-path-c-*.cache files older than CACHE_TTL_SECONDS."""
    cutoff = time.time() - CACHE_TTL_SECONDS
    try:
        for p in Path("/tmp").glob("claude-path-c-*.cache"):
            try:
                if p.stat().st_mtime < cutoff:
                    p.unlink()
            except (FileNotFoundError, OSError):
                continue
    except Exception:
        pass


def read_label_cache(path: Path) -> str | None:
    """Returns 'PATH_C', 'NOT_PATH_C', or None if cache miss/expired."""
    try:
        text = path.read_text().strip()
        marker, ts_str = text.split("\n", 1)
        if time.time() - float(ts_str) > LABEL_CACHE_TTL_SECONDS:
            return None
        if marker in ("PATH_C", "NOT_PATH_C"):
            return marker
    except (FileNotFoundError, ValueError, OSError):
        pass
    return None


def write_label_cache(path: Path, marker: str) -> None:
    try:
        path.write_text(f"{marker}\n{time.time()}")
    except OSError:
        pass


def fetch_label_status(issue_number: str) -> str:
    """Return 'PATH_C' if multi-task labelled, else 'NOT_PATH_C'.

    On any failure (gh missing, network, timeout, parse), returns 'NOT_PATH_C'
    so enforcement is fail-open.
    """
    try:
        result = subprocess.run(
            [
                "gh", "issue", "view", issue_number,
                "--repo", _pipeline_repo(),
                "--json", "labels",
                "--jq", ".labels[].name",
            ],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return "NOT_PATH_C"
        labels = {line.strip() for line in result.stdout.splitlines() if line.strip()}
        return "PATH_C" if "multi-task" in labels else "NOT_PATH_C"
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return "NOT_PATH_C"


def get_label_status(session_id: str, issue_number: str) -> str:
    cache = label_cache_path(session_id, issue_number)
    cached = read_label_cache(cache)
    if cached is not None:
        return cached
    fresh = fetch_label_status(issue_number)
    write_label_cache(cache, fresh)
    return fresh


def _is_trivial_target(p: PurePosixPath) -> bool:
    """Reject targets that would authorize the entire repo, root, or anything
    reachable via parent-traversal only ('.', '/', '..', '../..', etc.).
    """
    s = str(p)
    if s in (".", "", "/"):
        return True
    if not p.is_absolute() and all(part in ("..", ".") for part in p.parts):
        return True
    return False


def collect_authorized_dirs(session_id: str) -> set[PurePosixPath]:
    """Read every dispatch log for the current session and return the set of
    directories authorized by `target=<dir>` sentinels in tdd-implementer
    dispatches.
    """
    authorized: set[PurePosixPath] = set()
    log_dir = project_dir() / ".claude" / "logs" / "subagents"
    if not log_dir.is_dir():
        return authorized
    # Bound scan growth at O(recent-logs) as .claude/logs/subagents/ accumulates
    # over time. Stale logs are skipped without the json.loads cost; correctness
    # of session-scoping is still handled by the session_id check below.
    cutoff = time.time() - LOG_MTIME_WINDOW_SECONDS
    for json_path in log_dir.glob("*.json"):
        try:
            if json_path.stat().st_mtime < cutoff:
                continue
        except OSError:
            continue
        try:
            data = json.loads(json_path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if data.get("session_id") != session_id:
            continue
        if data.get("subagent_type") != "tdd-implementer":
            continue
        haystack = (data.get("description", "") or "") + "\n" + (data.get("prompt", "") or "")
        for match in SENTINEL_RE.finditer(haystack):
            raw = match.group(1)
            try:
                candidate = PurePosixPath(raw)
            except (TypeError, ValueError):
                continue
            if _is_trivial_target(candidate):
                log_error(f"rejected trivial target sentinel: raw={raw!r}")
                continue
            authorized.add(candidate)
    return authorized


def is_authorized(file_path: str, authorized_dirs: set[PurePosixPath]) -> bool:
    if not authorized_dirs:
        return False
    try:
        target = PurePosixPath(file_path)
    except (TypeError, ValueError):
        return False
    for ancestor in [target] + list(target.parents):
        if ancestor in authorized_dirs:
            return True
    return False


def main() -> int:
    # Escape hatch + non-pipeline session: cheap exits before any I/O work.
    if os.environ.get("ALLOW_ORCHESTRATOR_EDIT") == "true":
        return 0
    issue_number = os.environ.get("CLAUDE_PIPELINE_ISSUE_NUMBER", "").strip()
    if not issue_number:
        return 0

    # Only pipeline sessions write /tmp/claude-path-c-*.cache files, so only
    # pipeline sessions pay the sweep cost. Non-pipeline Edit/Write calls exit
    # above on the zero-I/O fast path.
    sweep_stale_caches()

    data = read_event_stdin()

    tool_name = data.get("tool_name", "")
    if tool_name not in ("Edit", "Write"):
        return 0

    tool_input = data.get("tool_input") or {}
    file_path = tool_input.get("file_path", "")
    if not file_path:
        return 0

    if is_allowlisted(file_path):
        return 0

    session_id = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", "unknown")

    if get_label_status(session_id, issue_number) != "PATH_C":
        return 0

    authorized = collect_authorized_dirs(session_id)
    if is_authorized(file_path, authorized):
        return 0

    print(
        "BLOCKED: PATH C (multi-task issue #{n}) requires dispatching a "
        "tdd-implementer subagent before editing impl files.\n"
        "  File: {f}\n"
        "  Fix: dispatch Agent(subagent_type='tdd-implementer', "
        "prompt='target=<dir>/ ...') for the directory containing this file, "
        "then retry the edit.\n"
        "  Escape hatch: export ALLOW_ORCHESTRATOR_EDIT=true (audit the "
        "log after the run).".format(n=issue_number, f=file_path),
        file=sys.stderr,
    )
    return 2


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception:
    log_error(traceback.format_exc())
    sys.exit(0)
