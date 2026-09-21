"""
PreToolUse hook - blocks Bash commands that read GitHub issue/PR *comments*
without routing through the trusted comment filter, and direct invocations of
fetch-issue-attachments.sh. This is defense-in-depth layer three for
comment-trust (#549): the helper (scripts/filter-trusted-comments.sh, #545)
hard-drops untrusted-author comment bytes; this hook steers callers toward it
so a forgetful skill or prompt-injection cannot smuggle raw untrusted comment
text into the agent's context via a bare `gh ... view --json ...comments...`.

Blocked (exit 2 + BLOCKED: stderr):
  - `gh issue view ... --json <fields>` where `comments` is one of the fields
  - `gh pr view ... --json <fields>`    where `comments` is one of the fields
    (both the `--json body,comments` and `--json=body,comments` forms)
  - any command invoking `fetch-issue-attachments.sh`

Allowed (exit 0):
  - any command containing `filter-trusted-comments.sh` (the trusted helper
    itself shells out to `gh issue view --json body,comments`; checked FIRST)
  - `gh issue/pr view` whose `--json` fields do NOT include `comments`
  - everything else

Scope: decides from DEQUOTED SEGMENTS (hooks/command_mask.py: `segments()`,
depth-1 recursion into a `-c`/`eval` operand) rather than a whole-text regex,
so a raw form living only in a quoted/heredoc/pattern operand is not a
command; an unterminated quote falls back to the pre-#1321 whole-text scan
(`_legacy_scan`, fail closed, never fewer blocks). Two further known gaps,
accepted as out of this layer's contract scope (the helper remains the
hard-drop boundary): (1) only the first `--json` flag is inspected, though
`gh` itself rejects duplicate `--json` flags; (2) the native
`gh issue/pr view --comments` boolean flag (no `--json`) is not blocked - a
candidate follow-up if the defense surface widens beyond `--json ...comments...`.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from subagent_log_utils import read_event_stdin  # noqa: E402
from command_mask import segments, head_index  # noqa: E402

HELPER = "filter-trusted-comments.sh"
_SHELL_BASENAMES = {"bash", "sh", "zsh", "dash", "ksh", "source", "."}

HELPER_HINT = (
    "Read issue/PR comments through `scripts/filter-trusted-comments.sh "
    "<N>` instead - it hard-drops comment bytes from untrusted authors "
    "before they reach your context (see #545 / #549). Raw "
    "`--json ...comments...` reads and direct fetch-issue-attachments.sh "
    "calls bypass that trust filter."
)


def _basename(word):
    return word.strip("\"'").rsplit("/", 1)[-1]


def _json_field_list(command):
    """Return the comma-split `--json` field list, or None if absent.
    Handles both `--json body,comments` and `--json=body,comments`.
    Used only by `_legacy_scan` (whole-text, unterminated-quote fallback)."""
    m = re.search(r"--json[=\s]+([A-Za-z0-9_,]+)", command)
    if not m:
        return None
    return [f.strip() for f in m.group(1).split(",") if f.strip()]


def _reads_comments(words):
    """True iff `words` is a `gh issue|pr view` segment whose (first)
    `--json` field list includes `comments`."""
    i = head_index(words)
    if i == -1 or _basename(words[i]) != "gh":
        return False
    if words[i + 1:i + 3] not in (["issue", "view"], ["pr", "view"]):
        return False
    for j in range(i + 3, len(words)):
        w = words[j]
        if w == "--json":
            fields_str = words[j + 1] if j + 1 < len(words) else ""
        elif w.startswith("--json="):
            fields_str = w[len("--json="):]
        else:
            continue
        fields = [f.strip() for f in fields_str.split(",") if f.strip()]
        return "comments" in fields
    return False


def _invokes_attachments(words):
    """True iff `words`' command word (or, for a shell-headed segment, its
    first non-flag operand) basenames to fetch-issue-attachments.sh."""
    i = head_index(words)
    if i == -1:
        return False
    candidates = [words[i]]
    if _basename(words[i]) in _SHELL_BASENAMES:
        nxt = next((w for w in words[i + 1:] if not w.startswith("-")), None)
        if nxt is not None:
            candidates.append(nxt)
    return any(_basename(c) == "fetch-issue-attachments.sh" for c in candidates)


def _legacy_scan(command: str) -> int:
    """Pre-#1321 whole-text scan - used ONLY when segments() cannot parse the
    command (unterminated quote). Fail closed: never fewer blocks than
    before #1321."""
    if re.search(r"\bgh\s+(?:issue|pr)\s+view\b", command):
        fields = _json_field_list(command)
        if fields and "comments" in fields:
            print(
                "BLOCKED: raw `gh ... view --json ...comments...` bypasses "
                "the comment-trust filter.\n" + HELPER_HINT,
                file=sys.stderr,
            )
            return 2
    if "fetch-issue-attachments.sh" in command:
        print(
            "BLOCKED: direct `fetch-issue-attachments.sh` bypasses the "
            "comment-trust filter.\n" + HELPER_HINT,
            file=sys.stderr,
        )
        return 2
    return 0


def main():
    data = read_event_stdin()
    command = data.get("tool_input", {}).get("command", "")
    if not command:
        return 0

    # Allow-by-presence FIRST, on the RAW text (Case H): the trusted helper
    # internally runs `gh issue view --json body,comments`, so its own
    # command string (and any pipeline routing through it) must pass before
    # the bypass checks below.
    if HELPER in command:
        return 0

    segs = segments(command)
    if segs is None:
        return _legacy_scan(command)

    for _, words in segs:
        if _reads_comments(words):
            print(
                "BLOCKED: raw `gh ... view --json ...comments...` bypasses "
                "the comment-trust filter.\n" + HELPER_HINT,
                file=sys.stderr,
            )
            return 2
        if _invokes_attachments(words):
            print(
                "BLOCKED: direct `fetch-issue-attachments.sh` bypasses the "
                "comment-trust filter.\n" + HELPER_HINT,
                file=sys.stderr,
            )
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
