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
import os
import re
import subprocess
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402
from subagent_log_utils import read_event_stdin  # noqa: E402

GH_TIMEOUT_SECONDS = 10
ROLLUP_RE = re.compile(r"\bgh\s+pr\s+view\s+(\d+)\b.*--json\s+statusCheckRollup")
WATCH_RE = re.compile(r"\bgh\s+pr\s+checks\s+(\d+)\b.*--watch\b")
APPROVED_RE = re.compile(r"\bgh\s+pr\s+comment\s+(\d+)\b.*--body\b.*\bApproved\b")


def project_dir() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))


def tool_use_log_path() -> Path:
    return project_dir() / ".claude" / "logs" / "tool-use.log"


def error_log_path() -> Path:
    return project_dir() / ".claude" / "logs" / "enforce-ci-wait-errors.log"


def state_dir() -> Path:
    return project_dir() / ".claude" / "logs" / "enforce-ci-wait-state"


def _count_file(session_id: str) -> Path:
    return state_dir() / f"{session_id}.count"


def _read_count(session_id: str) -> int:
    try:
        return int(_count_file(session_id).read_text().strip() or "0")
    except (OSError, ValueError):
        return 0


def _write_count(session_id: str, n: int) -> None:
    try:
        state_dir().mkdir(parents=True, exist_ok=True)
        _count_file(session_id).write_text(str(n))
    except OSError:
        pass


def _clear_count(session_id: str) -> None:
    try:
        _count_file(session_id).unlink()
    except (FileNotFoundError, OSError):
        pass


def _pr_number_from_rows(rows) -> str | None:
    """Return the PR number from any rollup, watch, or comment row."""
    for _ts, summary in rows:
        for rx in (APPROVED_RE, WATCH_RE, ROLLUP_RE):
            m = rx.search(summary)
            if m:
                return m.group(1)
    return None


def _escalate(issue_number: str, pr_number: str | None, reason: str) -> None:
    """Best-effort: label issue needs-human and post a PR comment.

    Both calls are wrapped in try/except — escalation aids triage but must
    not prevent the block itself.
    """
    repo = _read_config("PIPELINE_REPO", "")
    if issue_number:
        try:
            subprocess.run(
                ["gh", "issue", "edit", issue_number,
                 "--repo", repo, "--add-label", "needs-human"],
                capture_output=True, text=True, timeout=GH_TIMEOUT_SECONDS,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass
    if pr_number:
        body = (
            "## CI-wait gate fired (third block)\n\n"
            f"The `enforce-ci-wait` Stop hook blocked this evaluate-issue-pr "
            f"session three times. Latest reason:\n\n> {reason}\n\n"
            "Issue labelled `needs-human` for triage."
        )
        try:
            subprocess.run(
                ["gh", "pr", "comment", pr_number,
                 "--repo", repo, "--body", body],
                capture_output=True, text=True, timeout=GH_TIMEOUT_SECONDS,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass


def _block(session_id: str, rows, reason: str) -> int:
    sys.stderr.write(reason)
    new_count = _read_count(session_id) + 1
    _write_count(session_id, new_count)
    if new_count >= 3:
        issue_number = os.environ.get("CLAUDE_PIPELINE_ISSUE_NUMBER", "").strip()
        _escalate(issue_number, _pr_number_from_rows(rows), reason)
    return 2


def _session_bash_rows(session_id: str):
    """Yield (timestamp, summary) tuples for Bash rows in this session.

    Raises OSError if the log path is unreadable/corrupt — the top-level
    try/except converts that to a fail-open exit with an errors.log entry.
    """
    log = tool_use_log_path()
    if not log.exists():
        return
    text = log.read_text()
    needle = f"session={session_id}"
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) < 5:
            continue
        ts, phase, tool, sess, summary = cols[0], cols[1], cols[2], cols[3], "\t".join(cols[4:])
        if tool != "Bash" or sess != needle:
            continue
        # Each tool call produces a pre+post pair; only count once.
        if phase != "post":
            continue
        yield ts, summary


def _first_rollup_pr(rows) -> str | None:
    for _ts, summary in rows:
        m = ROLLUP_RE.search(summary)
        if m:
            return m.group(1)
    return None


def _gh_rollup_length(pr_number: str) -> int | None:
    try:
        result = subprocess.run(
            [
                "gh", "pr", "view", pr_number,
                "--repo", _read_config("PIPELINE_REPO", ""),
                "--json", "statusCheckRollup",
                "--jq", ". | length",
            ],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return None
        return int(result.stdout.strip() or "0")
    except (subprocess.TimeoutExpired, FileNotFoundError, ValueError, OSError):
        return None


def _gh_failed_check_count(pr_number: str) -> int | None:
    try:
        result = subprocess.run(
            [
                "gh", "pr", "view", pr_number,
                "--repo", _read_config("PIPELINE_REPO", ""),
                "--json", "statusCheckRollup",
                "--jq",
                '[.statusCheckRollup[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED")] | length',
            ],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return None
        return int(result.stdout.strip() or "0")
    except (subprocess.TimeoutExpired, FileNotFoundError, ValueError, OSError):
        return None


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
    data = read_event_stdin()
    session_id = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", "")
    if not session_id:
        return 0

    rows = list(_session_bash_rows(session_id))
    pr_number = _first_rollup_pr(rows)
    if pr_number is None:
        # No rollup query happened at all — the skill hasn't reached step 5 yet.
        # Treat as out-of-scope (e.g., session aborted before evaluation began).
        return 0

    length = _gh_rollup_length(pr_number)
    if length is None or length == 0:
        # No CI configured — skip the gate.
        return 0

    # CI present. Require a --watch invocation for this session.
    watch_ts = None
    for ts, summary in rows:
        if WATCH_RE.search(summary):
            watch_ts = ts
            break
    if watch_ts is None:
        return _block(session_id, rows,
            "CI-wait gate: --watch invocation not found for this session.\n"
            "Step 5b of evaluate-issue-pr requires:\n"
            "  timeout 600 gh pr checks <PR> --watch --fail-fast --interval 30\n"
            "Run that command in the FOREGROUND (a backgrounded Bash returns\n"
            "immediately and ends the subagent's turn), then retry Stop.\n",
        )

    # Require a second rollup query after the --watch.
    post_watch_rollup = False
    for ts, summary in rows:
        if ts > watch_ts and ROLLUP_RE.search(summary):
            post_watch_rollup = True
            break
    if not post_watch_rollup:
        return _block(session_id, rows,
            "CI-wait gate: final rollup not re-checked after --watch.\n"
            "Step 5c of evaluate-issue-pr requires re-reading statusCheckRollup\n"
            "after --watch completes:\n"
            "  gh pr view <PR> --repo <REPO> --json statusCheckRollup ...\n"
            "Run that command, then retry Stop.\n",
        )

    # Block Approved verdicts when the final rollup contains FAILURE/CANCELLED.
    approved_pr = None
    for _ts, summary in rows:
        m = APPROVED_RE.search(summary)
        if m:
            approved_pr = m.group(1)
            break
    if approved_pr is not None:
        failed = _gh_failed_check_count(approved_pr)
        if failed is not None and failed > 0:
            return _block(session_id, rows,
                "CI-wait gate: Approved verdict with failing CI.\n"
                f"PR #{approved_pr} has {failed} FAILURE/CANCELLED check(s) in the\n"
                "final rollup. Re-evaluate the PR with a Flagged verdict, or fix\n"
                "the failing job and re-run Step 5 before approving.\n",
            )

    _clear_count(session_id)
    return 0


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception:
    log_error(traceback.format_exc())
    sys.exit(0)
