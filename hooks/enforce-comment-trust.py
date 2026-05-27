"""
PreToolUse hook - blocks Bash commands that read GitHub issue/PR *comments*
without routing through the trusted comment filter, and direct invocations of
fetch-issue-attachments.sh. This is defense-in-depth layer three for
comment-trust (#549): the helper (scripts/filter-trusted-comments.sh, #545)
hard-drops untrusted-author comment bytes; this hook steers callers toward it
so a forgetful skill or prompt-injection cannot smuggle raw untrusted comment
text into the agent's context via a bare `gh ... view --json ...comments...`.

Blocked (exit 1 + BLOCKED: stderr):
  - `gh issue view ... --json <fields>` where `comments` is one of the fields
  - `gh pr view ... --json <fields>`    where `comments` is one of the fields
    (both the `--json body,comments` and `--json=body,comments` forms)
  - any command invoking `fetch-issue-attachments.sh`

Allowed (exit 0):
  - any command containing `filter-trusted-comments.sh` (the trusted helper
    itself shells out to `gh issue view --json body,comments`; checked FIRST)
  - `gh issue/pr view` whose `--json` fields do NOT include `comments`
  - everything else

Scope: only literal `tool_input.command` text is inspected. Reads hidden inside
$(...) command substitutions or HEREDOC bodies are NOT resolved - same known
limitation as hooks/check-ci-skip-markers.py.
"""
import json
import re
import sys

HELPER = "filter-trusted-comments.sh"

HELPER_HINT = (
    "Read issue/PR comments through `scripts/filter-trusted-comments.sh "
    "<N>` instead - it hard-drops comment bytes from untrusted authors "
    "before they reach your context (see #545 / #549). Raw "
    "`--json ...comments...` reads and direct fetch-issue-attachments.sh "
    "calls bypass that trust filter."
)


def _json_field_list(command):
    """Return the comma-split `--json` field list, or None if absent.
    Handles both `--json body,comments` and `--json=body,comments`."""
    m = re.search(r"--json[=\s]+([A-Za-z0-9_,]+)", command)
    if not m:
        return None
    return [f.strip() for f in m.group(1).split(",") if f.strip()]


def main():
    data = json.load(sys.stdin)
    command = data.get("tool_input", {}).get("command", "")
    if not command:
        return 0

    # Allow-by-presence FIRST: the trusted helper internally runs
    # `gh issue view --json body,comments`, so its own command string (and any
    # pipeline routing through it) must pass before the bypass checks below.
    if HELPER in command:
        return 0

    # Bypass 1: raw `gh issue/pr view --json ...comments...`.
    if re.search(r"\bgh\s+(?:issue|pr)\s+view\b", command):
        fields = _json_field_list(command)
        if fields and "comments" in fields:
            print(
                "BLOCKED: raw `gh ... view --json ...comments...` bypasses "
                "the comment-trust filter.\n" + HELPER_HINT,
                file=sys.stderr,
            )
            return 1

    # Bypass 2: direct attachment fetch.
    if "fetch-issue-attachments.sh" in command:
        print(
            "BLOCKED: direct `fetch-issue-attachments.sh` bypasses the "
            "comment-trust filter.\n" + HELPER_HINT,
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
