"""
PreToolUse hook — restricts file operations to the project directory and ~/.claude/.
Exits 2 (blocked) if a tool targets a path outside those boundaries.
"""
import os
import re
import sys
from pathlib import Path

PLUGIN_ROOT = os.environ.get("CLAUDE_PLUGIN_ROOT")
if not PLUGIN_ROOT:
    print(
        "restrict_paths.py: CLAUDE_PLUGIN_ROOT not set in hook env — "
        "cannot resolve plugin paths. Likely a harness env-propagation "
        "regression (see issue #339). Allowing this call (fail-open) so "
        "the assistant can recover. To re-enable path restriction, ensure "
        "CLAUDE_PLUGIN_ROOT is exported in the harness env before "
        "invoking Claude Code.",
        file=sys.stderr,
    )
    sys.exit(0)

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402
from subagent_log_utils import read_event_stdin  # noqa: E402

data = read_event_stdin()
tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input", {})

PROJECT_DIR = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))
CLAUDE_HOME = os.path.realpath(os.path.expanduser("~/.claude"))

ALLOWED_ROOTS = [PROJECT_DIR, CLAUDE_HOME]

# Also allow worktrees that live outside the project dir (sibling dirs like <prefix>-<N>-*)
_WORKTREE_PREFIX = _read_config("PIPELINE_WORKTREE_PREFIX", "wt", project_dir=PROJECT_DIR)
WORKTREE_PATTERN = re.compile(re.escape(os.path.dirname(PROJECT_DIR)) + r"/" + re.escape(_WORKTREE_PREFIX) + r"-\d+-")

# Protected paths — block modification of settings and hook files (in project
# and worktrees). Enforced for Write/Edit AND for any path the Bash extractor
# surfaces (the protected loop below is no longer gated to Write/Edit — see
# #964: an inline `sed -i`/`>`/`cp-onto` could otherwise disarm a guard in
# place). The 4th pattern protects the plugin's OWN cache hooks dir
# (`…/.claude/plugins/cache/<marketplace>/<plugin>/<ver>/hooks/…`): chosen over
# "out of scope" because protecting the plugin's own guards matches this hook's
# stated intent and #964's threat model (disarming a guard mid-run).
PROTECTED_PATTERNS = [
    r"\.claude/settings\.json$",
    r"\.claude/settings\.local\.json$",
    r"\.claude/hooks/",
    r"\.claude/plugins/cache/[^/]+/[^/]+/[^/]+/hooks/",
]

# Command-string protected-token scan (Bash branch). The absolute+exists path
# extractor misses RELATIVE disarm targets (e.g. "> .claude/settings.json"),
# so scan the raw command for protected control-file references directly.
# Inherently porous (a payload hidden in a script or base64-decoded evades any
# command-string scan — same limit as the boundary check); this raises the bar
# against the obvious inline disarm. Durable fix (immutable guards) is out of
# scope (see #964 Notes).
PROTECTED_CMD_PATTERNS = [
    r"(?:^|[\s=>'\"|&;(])(?:\./)?(?:[^\s'\";|&>]*/)?\.claude/settings\.json\b",
    r"(?:^|[\s=>'\"|&;(])(?:\./)?(?:[^\s'\";|&>]*/)?\.claude/settings\.local\.json\b",
    r"(?:^|[\s=>'\"|&;(])(?:\./)?(?:[^\s'\";|&>]*/)?\.claude/hooks/",
    r"\.claude/plugins/cache/[^\s'\";|&>]*/hooks/",
]


def is_protected(path: str) -> bool:
    """Return True if path is a settings or hook file that should not be modified."""
    real = os.path.realpath(path)
    for pattern in PROTECTED_PATTERNS:
        if re.search(pattern, real):
            return True
    return False


def _command_has_worktree_dest(command: str) -> bool:
    """Return True if the command names a worktree-sibling absolute destination.

    The command-string protected-token scan (#964) blocks in-place disarm of a
    control file (`sed -i .claude/settings.json`). But a legitimate
    worktree-destination copy (`cp .claude/hooks/x <parent>/<prefix>-N-/.claude/
    hooks/x`) must still be allowed — that is the sync case, not the disarm
    case. We detect it cheaply by reusing the existing WORKTREE_PATTERN: if any
    absolute path token in the command matches the worktree-sibling shape, treat
    the whole command as a destination copy and skip the protected scan.
    """
    for m in re.finditer(r'(/[^\s"\';<>|&]+)', command):
        if WORKTREE_PATTERN.match(m.group(1)):
            return True
    return False


def _worktree_pointer_allows(real: str) -> bool:
    """Allow git operations on a linked worktree's real git dir.

    A linked git worktree's real git dir lives at <main>/.git/worktrees/<slug>/,
    which resolves OUTSIDE the worktree's CLAUDE_PROJECT_DIR. Git records the
    linkage bidirectionally: the worktree's `.git` file names the git dir, and
    the git dir holds a `gitdir` back-link file naming the worktree's `.git`.
    We trust the target ONLY via that back-link resolving back into an allowed
    root. (Issue #337.)

    Defense narrowing (why this can't widen the boundary):
      (i)   the requested path must itself match the worktree-git-dir shape
            `.../.git/worktrees/<slug>/...`, so a plain out-of-boundary read
            (e.g. the system password file) never qualifies;
      (ii)  the trust anchor is the back-link FILE *inside the target dir*
            pointing back into an allowed root. An out-of-boundary attacker
            cannot forge it: creating that back-link file in the out-of-boundary
            target is itself a blocked write. A worktree-side pointer the agent
            could rewrite under PROJECT_DIR is never consulted — only the
            target-side back-link is.
    No existing protected/blocked pattern is widened.
    """
    m = re.search(r"^(.*/\.git/worktrees/[^/]+)(?:/|$)", real)
    if not m:
        return False
    gitdir = m.group(1)  # the linked worktree's real git dir, per the request
    backlink = os.path.join(gitdir, "gitdir")
    if not os.path.isfile(backlink):
        return False
    try:
        pointer = os.path.realpath(open(backlink, encoding="utf-8").read().strip())
    except OSError:
        return False
    for root in ALLOWED_ROOTS:
        if pointer == root or pointer.startswith(root + os.sep):
            return True
    if WORKTREE_PATTERN.match(pointer):
        return True
    return False


def is_allowed(path: str) -> bool:
    if not path:
        return True
    real = os.path.realpath(path)
    for root in ALLOWED_ROOTS:
        if real == root or real.startswith(root + os.sep):
            return True
    if WORKTREE_PATTERN.match(real):
        return True
    if _worktree_pointer_allows(real):
        return True
    return False


def extract_paths() -> list[str]:
    """Extract file paths from tool input based on tool type."""
    paths = []

    if tool_name in ("Read", "Write", "Edit"):
        p = tool_input.get("file_path", "")
        if p:
            paths.append(p)

    elif tool_name in ("Glob", "Grep"):
        p = tool_input.get("path", "")
        if p:
            paths.append(p)

    elif tool_name == "Bash":
        # Best-effort: extract absolute paths from the command string.
        command = tool_input.get("command", "")
        # Pre-scrub env-var literals so unsubstituted ${VAR} / $VAR tokens
        # in the command text can't false-positive the path extractor. Two
        # passes: curly form first (explicit braces), then bare form on the
        # residue. Uppercase + underscore matches conventional env-var
        # naming and avoids consuming shell positional/special params like
        # $1, $?, $@ that can't be paths anyway. See #353.
        scrubbed = re.sub(r"\$\{[A-Z_][A-Z0-9_]*\}", "", command)
        scrubbed = re.sub(r"\$[A-Z_][A-Z0-9_]*", "", scrubbed)
        for m in re.finditer(r'(?:"|\')?(/[^\s"\';<>|&]+)(?:"|\')?', scrubbed):
            candidate = m.group(1)
            # Skip the bare jq alternative-operator token ("//" with nothing
            # after, captured when surrounded by whitespace as in
            # `.bar // empty`). The candidate must be exactly "//" — broader
            # leading-double-slash skips would mask real out-of-boundary
            # paths like "//etc/passwd" (POSIX collapses // to /). Real
            # boundary-bypass attempts via // are caught downstream by
            # is_allowed → os.path.realpath. See #353.
            if candidate == "//":
                continue
            if candidate in ("/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr"):
                continue
            if candidate.startswith("/tmp"):
                continue
            # Skip fragments that aren't real paths (e.g. branch names
            # like /rerate-after-edits or commit message fragments like /Reject)
            if not os.path.exists(candidate):
                continue
            paths.append(candidate)

    return paths


paths = extract_paths()

# Check for protected file edits. Runs for ALL extracted paths regardless of
# tool (not just Write/Edit) so the Bash absolute-path extractor output is
# checked too — closing the in-place inline-disarm gap (#964).
for path in paths:
    if is_protected(path):
        print(
            f"BLOCKED: cannot modify protected file: {path}",
            file=sys.stderr,
        )
        sys.exit(2)

# Bash command-string protected-token scan (#964): the absolute+exists
# extractor never sees RELATIVE disarm targets, so scan the raw command for
# protected control-file references. Skipped when the command names a
# worktree-sibling destination (the legit sync/destination-copy carve-out).
if tool_name == "Bash":
    command = tool_input.get("command", "")
    if not _command_has_worktree_dest(command):
        for pat in PROTECTED_CMD_PATTERNS:
            if re.search(pat, command):
                print(
                    "BLOCKED: cannot modify protected file "
                    "(Bash command targets a protected control file)",
                    file=sys.stderr,
                )
                sys.exit(2)

# Check for path boundary violations
for path in paths:
    if not is_allowed(path):
        print(
            f"BLOCKED: path outside project boundary: {path}",
            file=sys.stderr,
        )
        sys.exit(2)
