"""
PreToolUse hook - blocks `gh pr create` and `git commit -m` invocations
whose proposed title/body/subject contains a GitHub Actions CI-blocking
marker. GH Actions honors these markers in commit subjects and PR titles
and silently skips ALL workflows on the affected push, which is the
opposite of what an agent fixing CI usually wants.

Markers blocked (case-insensitive):
    [skip ci]   [ci skip]   [skip-ci]   [ci-skip]
    [no ci]     [no-ci]     ***NO_CI***

Safe rephrasings the agent should use instead:
    skip-ci (no brackets)
    skip CI (no brackets)
    `skip ci` (wrapped in backticks - GH does not honor markup)

Scope:
  - `gh pr create`: only --title and --body argument *values* are scanned.
  - `git commit`: only -m / --message argument values are scanned.
  - All other commands pass through (exit 0). HEREDOC bodies passed via
    `--body "$(cat <<EOF ... EOF)"` are NOT reliably parseable from
    tool_input.command and are accepted as a known limitation.
"""
import json
import re
import sys

MARKER_RE = re.compile(
    r"\[(?:skip|no)[\s-]?ci\]|\[ci[\s-]?skip\]|\*\*\*NO_CI\*\*\*",
    re.IGNORECASE,
)


def _extract_arg_values(command: str, flags: tuple[str, ...]) -> list[str]:
    """Return values of each occurrence of any --flag/-flag in command.
    Handles --flag=val, --flag val, --flag "quoted val", --flag 'quoted val'.
    Does NOT attempt to resolve $(...) command substitutions or HEREDOCs."""
    values: list[str] = []
    for flag in flags:
        for m in re.finditer(
            rf'{re.escape(flag)}=(?:"([^"]*)"|\'([^\']*)\'|(\S+))', command
        ):
            values.append(next(g for g in m.groups() if g is not None))
        for m in re.finditer(
            rf'{re.escape(flag)}\s+(?:"([^"]*)"|\'([^\']*)\'|(\S+))', command
        ):
            values.append(next(g for g in m.groups() if g is not None))
    return values


def main() -> int:
    data = json.load(sys.stdin)
    command = data.get("tool_input", {}).get("command", "")
    if not command:
        return 0

    candidates: list[str] = []
    if re.search(r"\bgh\s+pr\s+create\b", command):
        candidates.extend(_extract_arg_values(command, ("--title", "--body")))
    if re.search(r"\bgit\s+commit\b", command):
        candidates.extend(_extract_arg_values(command, ("-m", "--message")))

    if not candidates:
        return 0

    for value in candidates:
        match = MARKER_RE.search(value)
        if match:
            print(
                "BLOCKED: CI-blocking marker "
                f"{match.group(0)!r} found in the proposed text.\n"
                "GitHub Actions silently skips ALL workflows when commit "
                "subjects or PR titles contain the bracketed forms of "
                "skip ci / ci skip / no ci / no-ci, or ***NO_CI***.\n"
                "Substitute a safe rephrasing - e.g. 'skip-ci' (no "
                "brackets), 'skip CI' (no brackets), or wrap the literal "
                "in backticks like `skip ci` - and retry.",
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
