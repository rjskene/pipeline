"""PermissionRequest hook — the headless permission bridge (issue #1421).

A `claude -p` session has nobody to answer a permission prompt. The two
pre-existing options were both bad: `--dangerously-skip-permissions` grants
everything unseen, and `--permission-prompts none` denies everything that
would prompt. This hook adds a third: the escalation is written to a QUEUE
DIR as a file, the hook blocks polling for an answer file, and an interactive
operator session watching that dir answers it with
`scripts/permission-bridge.sh answer <id> allow|deny [msg]`.

Inertness is the load-bearing property. The hook is registered with matcher
`*`, and under the dogfood install `${CLAUDE_PLUGIN_ROOT}` points at the
operator's working tree — so this file runs in the operator's LIVE interactive
sessions too. With `PIPELINE_PERMISSION_BRIDGE_DIR` unset it exits 0 having
emitted nothing and having read nothing (the env check precedes the stdin
read), which Claude Code reads as "this hook expressed no opinion".

Exit-code contract — DIFFERENT from the PreToolUse guards in
docs/plugin-architecture.md: `PermissionRequest` does NOT honour exit 2. This
hook ALWAYS exits 0 and expresses allow/deny purely through the stdout JSON
envelope:

    {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                            "decision": {"behavior": "allow"|"deny",
                                         "message": "..."}}}

Fail-open direction is DENY, not allow. Timeout, an unreadable queue dir, a
malformed answer and any uncaught exception all emit `deny` with the
skip-and-continue message: an escalation the operator never saw must not be
silently granted. A crashed bridge must never wedge a headless session, which
is why every path ends in exactly one envelope on stdout and exit 0.

Queue-dir layout (one pair per escalation, both named by tool_use_id):
    <dir>/<id>.json    written by this hook — the request the operator reads
    <dir>/<id>.answer  written by the operator CLI — `allow` or `deny[\nmsg]`
"""
import json
import os
import re
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402
from subagent_log_utils import read_event_stdin  # noqa: E402

# Default deadline (seconds). 840 sits UNDER the 900 s `timeout` the manifest
# registers for this hook, so the bridge always resolves its own decision
# rather than being killed mid-poll with no envelope on stdout.
DEFAULT_TIMEOUT_SECONDS = 840
POLL_SECONDS = 2
# `wt-<N>` / `wt-<N>-<slug>` — the pipeline worktree basename shape. Matched on
# the cwd basename only, so an unrelated cwd yields "" rather than a guess.
WORKTREE_RE = re.compile(r"^[A-Za-z0-9]+-(\d+)(?:-.*)?$")
DENY_MESSAGE_TEMPLATE = (
    "no operator answer within {n} s — skip this step and continue; "
    "do not retry this call"
)
DENY_MALFORMED = (
    "the operator answer file was malformed (first line is neither `allow` nor "
    "`deny`) — skip this step and continue; do not retry this call"
)
DENY_CRASHED = (
    "the permission bridge failed — skip this step and continue; do not retry "
    "this call"
)


def project_dir() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))


def log_error(text: str) -> None:
    """Best-effort error log. Never raises — it is on the fail-open path."""
    try:
        p = project_dir() / ".claude" / "logs" / "permission-bridge-errors.log"
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a") as fh:
            fh.write(f"--- {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
            fh.write(text.rstrip() + "\n")
    except Exception:
        pass


def emit(behavior: str, message: str = "") -> None:
    decision = {"behavior": behavior}
    if message:
        decision["message"] = message
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decision,
        }
    }))


def resolve_timeout() -> int:
    """env first, then pipeline.config, then the built-in default."""
    raw = os.environ.get("PIPELINE_PERMISSION_BRIDGE_TIMEOUT", "").strip()
    if not raw:
        raw = _read_config("PIPELINE_PERMISSION_BRIDGE_TIMEOUT",
                           str(DEFAULT_TIMEOUT_SECONDS)).strip()
    try:
        n = int(float(raw))
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT_SECONDS
    return n if n > 0 else DEFAULT_TIMEOUT_SECONDS


def issue_from_cwd(cwd: str) -> str:
    """`#N` when the cwd basename is a pipeline worktree, else ""."""
    base = os.path.basename(str(cwd).rstrip("/"))
    m = WORKTREE_RE.match(base)
    return f"#{m.group(1)}" if m else ""


def safe_id(raw: str) -> str:
    """Filename-safe queue id. Never empty: a request with no tool_use_id
    still has to be answerable, so fall back to a per-call timestamp."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", str(raw or "").strip())
    return cleaned or f"noid-{int(time.time() * 1000)}"


def write_queue_file(path: Path, payload: dict) -> None:
    """Atomic write: tmp + os.replace, so the operator CLI never reads a
    half-written request (and no `.tmp` is left behind in the queue dir)."""
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        os.replace(str(tmp), str(path))
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


def read_answer(path: Path):
    """(behavior, message) from the answer file, or None when it is not there
    yet. ("deny", DENY_MALFORMED) when the first line is not a verdict."""
    try:
        raw = path.read_text()
    except OSError:
        return None
    lines = raw.splitlines()
    verdict = (lines[0].strip().lower() if lines else "")
    message = "\n".join(lines[1:]).strip()
    if verdict == "allow":
        return ("allow", message)
    if verdict == "deny":
        return ("deny", message or "denied by the operator — skip this step "
                                   "and continue; do not retry this call")
    return ("deny", DENY_MALFORMED)


def main() -> int:
    # --- Inertness gate. Runs BEFORE the stdin read so a registered-but-
    # unconfigured hook costs a process spawn and nothing else (#1421 Task 4
    # (a1) is the live probe of this exact property).
    bridge_dir = os.environ.get("PIPELINE_PERMISSION_BRIDGE_DIR", "").strip()
    if not bridge_dir:
        return 0

    data = read_event_stdin() or {}
    qid = safe_id(data.get("tool_use_id") or data.get("toolUseId") or "")
    cwd = data.get("cwd") or os.getcwd()
    timeout = resolve_timeout()

    qdir = Path(bridge_dir)
    qdir.mkdir(parents=True, exist_ok=True)
    queue_file = qdir / f"{qid}.json"
    answer_file = qdir / f"{qid}.answer"

    write_queue_file(queue_file, {
        "id": qid,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "session_id": data.get("session_id", ""),
        "cwd": cwd,
        "tool_name": data.get("tool_name", ""),
        "tool_input": data.get("tool_input", {}),
        "issue": issue_from_cwd(cwd),
    })

    deadline = time.monotonic() + timeout
    while True:
        answer = read_answer(answer_file)
        if answer is not None:
            emit(answer[0], answer[1])
            return 0
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            emit("deny", DENY_MESSAGE_TEMPLATE.format(n=timeout))
            return 0
        time.sleep(min(POLL_SECONDS, remaining))


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception:
    log_error(traceback.format_exc())
    # DENY, not allow: a bridge that crashed never showed the operator
    # anything, so granting the escalation would be granting it blind.
    emit("deny", DENY_CRASHED)
    sys.exit(0)
