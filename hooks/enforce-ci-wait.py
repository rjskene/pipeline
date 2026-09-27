"""Stop hook — enforces CI-wait discipline. Two branches, by session role.

EVAL-AGENT branch (CLAUDE_PIPELINE_SKILL=evaluate-issue-pr, unchanged):
reads .claude/logs/tool-use.log (filtered by session_id) and asserts that the
prescribed `gh pr view ... statusCheckRollup -> gh pr checks ... --watch ->
gh pr view ... statusCheckRollup` sequence was actually executed before the
agent attempts to Stop. An Approved verdict with a failing final rollup is
also blocked.

ORCHESTRATOR branch (#1424) — entered for any other session, but only acts
when PIPELINE_HEADLESS is true (env first, then pipeline.config) AND the
transcript's first user message is a `/pipeline:fullsend` invocation. It parses
that slate and denies Stop while any slate issue is `in-progress`, or `pr-open`
with no parked label (`block-*`, `manual-merge`, PIPELINE_LABELS_HUMAN,
PIPELINE_LABELS_EXCLUDED; `--manual-merge` on the command parks `pr-open` too,
because no label records that flag). Print mode exits the moment the model
stops calling tools, so a narrated "waiting on CI" strands the slate — the
denial tells the orchestrator to poll CI in the FOREGROUND instead. Capped at
ORCH_BLOCK_CAP blocks per session, then fail-open: a genuinely wedged session
must still be able to end.

Fail-open: any uncaught error logs to .claude/logs/enforce-ci-wait-errors.log
and exits 0. A hook bug must never brick evaluate-issue-pr or wedge an
orchestrator session; every `gh` failure in the orchestrator branch allows the
Stop and leaves an errors.log entry.

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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402
from subagent_log_utils import read_event_stdin  # noqa: E402
try:  # #1352 fail-open: a partial hook install (e.g. a legacy
    # subtree copy missing this file) must never crash a guard hook.
    from _deny_log import log_denial  # noqa: E402
except ImportError:
    def log_denial(*_args, **_kwargs):  # noqa: E302
        pass

GH_TIMEOUT_SECONDS = 10
# Orchestrator branch (#1424): how many Stop denials before fail-open.
ORCH_BLOCK_CAP = 40
FULLSEND_CMD = "/pipeline:fullsend"
FULLSEND_CMD_RE = re.compile(re.escape(FULLSEND_CMD))
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)
ISSUE_ID_RE = re.compile(r"\b(\d{1,7})\b")
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


def _block(session_id: str, rows, reason: str, escalate: bool = True) -> int:
    sys.stderr.write(reason)
    log_denial("enforce-ci-wait", "Stop", reason, "", session_id=session_id)
    new_count = _read_count(session_id) + 1
    _write_count(session_id, new_count)
    if escalate and new_count >= 3:
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



def _headless() -> bool:
    """True when PIPELINE_HEADLESS is set to "true".

    ENV FIRST: the launchers inject the knob into the child environment
    (scripts/calibration-run.sh, scripts/evolve-loop.sh) and
    pipeline.config.example declares it COMMENTED, so a config-only read would
    return "" on every real headless run. The config fallback covers an
    operator who uncomments it.
    """
    raw = os.environ.get("PIPELINE_HEADLESS", "").strip()
    if not raw:
        raw = _read_config("PIPELINE_HEADLESS", "")
    return raw.strip().lower() == "true"


def _first_user_text(path: str) -> str:
    """Return the first non-sidechain, non-meta user message's text, then stop.

    Bounded by construction — transcripts are large, and the slate is always in
    the first user turn. Raises OSError if the transcript is unreadable, which
    the top-level fail-open converts to an allow + errors.log entry.
    """
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            if (entry.get("type") != "user" or entry.get("isSidechain")
                    or entry.get("isMeta")):
                continue
            message = entry.get("message")
            if not isinstance(message, dict):
                return ""
            content = message.get("content")
            if isinstance(content, str):
                return content
            if isinstance(content, list):
                return "\n".join(
                    b.get("text", "") for b in content if isinstance(b, dict)
                )
            return ""
    return ""


def _slate_from_transcript(path) -> tuple[list[str], set[str]]:
    """Parse (issue ids, flags) from the transcript's first user message.

    The real slash-command shape is
      <command-name>/pipeline:fullsend</command-name>
      <command-args>1421 1418 --manual-merge</command-args>
    so <command-args> is read when present, with the bare-prose remainder
    (`/pipeline:fullsend 1421 1418`) as the fallback. Only bare integers become
    issue ids; `--`-prefixed tokens become flags.
    """
    if not path:
        return [], set()
    text = _first_user_text(path)
    if not FULLSEND_CMD_RE.search(text):
        return [], set()
    match = COMMAND_ARGS_RE.search(text)
    if match:
        argtext = match.group(1)
    else:
        tail = text.split(FULLSEND_CMD, 1)[1].splitlines()
        argtext = tail[0] if tail else ""
    tokens = argtext.split()
    ids = [t for t in tokens if ISSUE_ID_RE.fullmatch(t)]
    flags = {t for t in tokens if t.startswith("--")}
    return ids, flags


def _gh_issue_labels(issue_number: str):
    """Label names for an issue, or None on any gh failure (fail-open signal)."""
    try:
        result = subprocess.run(
            [
                "gh", "issue", "view", issue_number,
                "--repo", _read_config("PIPELINE_REPO", ""),
                "--json", "labels",
                "--jq", ".labels[].name",
            ],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return None
        return [ln.strip() for ln in result.stdout.splitlines() if ln.strip()]
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None


def _unfinished(labels, manual_merge: bool) -> str | None:
    """The label proving this slate issue still needs the orchestrator, or None.

    `--manual-merge` makes evaluate-issue-pr skip its merge step entirely and
    apply NO label, so under that flag `pr-open` is the finished state — without
    this arm a --manual-merge run would burn all ORCH_BLOCK_CAP denials.
    """
    if "in-progress" in labels:
        return "in-progress"
    if manual_merge:
        return None
    if "pr-open" not in labels:
        return None
    if any(name.startswith("block-") for name in labels):
        return None
    parked = {
        "manual-merge",
        _read_config("PIPELINE_LABELS_HUMAN", "human"),
        _read_config("PIPELINE_LABELS_EXCLUDED", "excluded"),
    }
    if parked & set(labels):
        return None
    return "pr-open"


def _orchestrator_stop(session_id: str, data) -> int:
    """Deny a headless fullsend Stop while the slate is still unfinished."""
    if not _headless():
        return 0
    if os.environ.get("CLAUDE_PIPELINE_SKILL", "").strip() not in ("", "fullsend"):
        return 0
    slate, flags = _slate_from_transcript(data.get("transcript_path", ""))
    if not slate:
        return 0
    manual_merge = "--manual-merge" in flags
    if _read_count(session_id) >= ORCH_BLOCK_CAP:
        return 0
    for issue_number in slate:
        labels = _gh_issue_labels(issue_number)
        if labels is None:
            log_error(
                f"orchestrator slate gate: gh issue view {issue_number} failed "
                "— allowing Stop (fail-open)"
            )
            return 0
        reason = _unfinished(labels, manual_merge)
        if reason is not None:
            return _block(
                session_id, [],
                f"slate unfinished: #{issue_number} {reason} — poll CI in the "
                "foreground with `timeout 590 gh pr checks <PR> --repo "
                '"$PIPELINE_REPO" --watch --interval 30` and continue; do not '
                "background the wait\n",
                escalate=False,
            )
    _clear_count(session_id)
    return 0


def main() -> int:
    data = read_event_stdin()
    session_id = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", "")
    if not session_id:
        return 0
    if os.environ.get("CLAUDE_PIPELINE_SKILL", "") != "evaluate-issue-pr":
        return _orchestrator_stop(session_id, data)

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
