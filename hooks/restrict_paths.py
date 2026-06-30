"""
PreToolUse hook — restricts file operations to the project directory and ~/.claude/.
Exits 2 (blocked) if a tool targets a path outside those boundaries.
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402
from subagent_log_utils import read_event_stdin  # noqa: E402

data = read_event_stdin()
tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input", {})

PROJECT_DIR = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))
CLAUDE_HOME = os.path.realpath(os.path.expanduser("~/.claude"))


def _resolve(path: str) -> str:
    """Anchor relative paths on PROJECT_DIR before realpath.

    A relative path is anchored on the project root (CLAUDE_PROJECT_DIR), not
    the hook process CWD.  This matters when the hook runs from a shell whose
    CWD is outside the project (e.g. an outer terminal); an in-repo relative
    path like `.venv-host/Scripts/python.exe` must resolve IN-project, not
    against the outer CWD.  Absolute paths and ``..``-escapes that climb
    outside PROJECT_DIR are unaffected — they still resolve to their real
    location via os.path.realpath, and the boundary check rejects anything
    that lands outside ALLOWED_ROOTS.  (Bug 1 fix — issue #1136.)
    """
    if not os.path.isabs(path):
        path = os.path.join(PROJECT_DIR, path)
    return os.path.realpath(path)

ALLOWED_ROOTS = [PROJECT_DIR, CLAUDE_HOME]

# Also allow worktrees that live outside the project dir (sibling dirs like <prefix>-<N>-*)
_WORKTREE_PREFIX = _read_config("PIPELINE_WORKTREE_PREFIX", "wt", project_dir=PROJECT_DIR)
WORKTREE_PATTERN = re.compile(re.escape(os.path.dirname(PROJECT_DIR)) + r"/" + re.escape(_WORKTREE_PREFIX) + r"-\d+-")

# Nested worktrees created by scripts/setup-worktree.sh live at
# <project>/.claude/worktrees/<prefix>-N-<slug>/ (and PATH-C leaves at
# <prefix>-N-<slug>-leaf-<x>/, also under .claude/worktrees/). Anchor on the
# REAL project root (re.escape(PROJECT_DIR)) so .claude/worktrees/ must be a
# DIRECT child of CLAUDE_PROJECT_DIR (production-faithful — setup-worktree.sh:67
# creates $MAIN_REPO/.claude/worktrees/<prefix>-N-<slug>). The prior pattern
# anchored on the free-floating .claude/worktrees/ SEGMENT, which matched the
# project-dir-independent constant substring ANYWHERE in a path — letting a
# hardcoded, non-existent token disarm the carve-out (#1067, the #1058 widening
# of the F7 bypass). Require a NON-empty slug ([^/]+) so an empty-slug
# `wt-12-/` token is no longer treated as a worktree. The LIVE main-repo path
# <project>/.claude/hooks/ has NO .claude/worktrees/ ancestor segment, so it
# never matches — keeping the disarm protection intact (#1058).
NESTED_WORKTREE_PATTERN = re.compile(
    re.escape(PROJECT_DIR) + r"/\.claude/worktrees/" + re.escape(_WORKTREE_PREFIX) + r"-\d+-[^/]+/"
)

# Worktree-ROOT extractors (no trailing slash) — capture the registered
# worktree directory a path lives under, so `_command_has_worktree_dest` can
# require THAT specific root to EXIST on disk (#1067). NESTED is the
# PROJECT_DIR-anchored <project>/.claude/worktrees/<prefix>-N-<slug> root;
# SIBLING is the <parent-of-project>/<prefix>-N-<slug> root. NESTED is checked
# first (more specific): a path that claims a nested worktree dest must have
# that nested root exist, even when the suite runs from INSIDE an outer
# worktree whose sibling shape would otherwise match incidentally.
NESTED_WORKTREE_ROOT_PATTERN = re.compile(
    re.escape(PROJECT_DIR) + r"/\.claude/worktrees/" + re.escape(_WORKTREE_PREFIX) + r"-\d+-[^/]+"
)
SIBLING_WORKTREE_ROOT_PATTERN = re.compile(
    re.escape(os.path.dirname(PROJECT_DIR)) + r"/" + re.escape(_WORKTREE_PREFIX) + r"-\d+-[^/]+"
)

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


def _is_in_worktree(real: str) -> bool:
    """True if real path is inside a recognized pipeline worktree (sibling OR nested).

    Sibling: <parent-of-project>/<prefix>-N-...  (WORKTREE_PATTERN)
    Nested:  <project>/.claude/worktrees/<prefix>-N-.../  (NESTED_WORKTREE_PATTERN)
    Used to exempt in-worktree edits of protected paths: such edits do not take
    effect until merge+pull, so they are not a live-guard disarm (#1058).
    """
    return bool(WORKTREE_PATTERN.match(real) or NESTED_WORKTREE_PATTERN.search(real))


def is_protected(path: str) -> bool:
    """Return True if path is a settings or hook file that should not be modified."""
    real = _resolve(path)
    # In-worktree edits (sibling OR nested) of protected paths are legitimate
    # work — the worktree copy is inert until merged+pulled — so they are NOT
    # the live-guard disarm this check exists to prevent. The live main-repo
    # path has no worktree ancestor and so is unaffected. (#1058)
    if _is_in_worktree(real):
        return False
    for pattern in PROTECTED_PATTERNS:
        if re.search(pattern, real):
            return True
    return False


def _resolved_worktree_root(real: str) -> str | None:
    """Return the registered-worktree ROOT dir that `real` lives under, else None.

    Prefers the PROJECT_DIR-anchored NESTED root (more specific): a path that
    claims a `<project>/.claude/worktrees/<prefix>-N-<slug>/...` destination is
    pinned to THAT nested worktree, not to whatever outer sibling worktree the
    suite may happen to run from. Falls back to the sibling root only when the
    path matches the sibling shape but not the nested one.
    """
    m = NESTED_WORKTREE_ROOT_PATTERN.match(real)
    if m:
        return m.group(0)
    m = SIBLING_WORKTREE_ROOT_PATTERN.match(real)
    if m:
        return m.group(0)
    return None


def _command_has_worktree_dest(command: str) -> bool:
    """True ONLY if the command's copy/move TARGET resolves to an EXISTING, registered worktree.

    The command-string protected-token scan (#964) blocks in-place disarm of a
    control file (`sed -i .claude/settings.json`). A legitimate
    worktree-destination copy (`cp .claude/hooks/x <worktree>/.claude/hooks/x`)
    must still be allowed — that is the sync case, not the disarm case.

    Hardening (#1067): the prior version returned True if ANY absolute token
    anywhere in the command matched the worktree regex — a pure string match
    with no realpath/exists/registration check, so a hardcoded NON-EXISTENT
    `.../.claude/worktrees/<prefix>-N-x/...` token appended anywhere disabled the
    WHOLE protected-command scan (#1058 widened this from a sibling shape to a
    project-dir-independent constant substring). Now a token only exempts the
    scan when it is:
      (i)   the POSITIONAL copy/move destination — the LAST path-shaped token
            (the dest of cp/mv/install/rsync and of a redirect target). This
            structurally defeats the "append a decoy token anywhere" shape: a
            trailing `: /bogus/...` no-op IS the last token, so the existence
            gate below is what rejects it;
      (ii)  os.path.realpath-resolved (collapses symlinks/.. — cannot escape
            upward); AND
      (iii) anchored on a registered worktree ROOT (PROJECT_DIR-anchored nested,
            else sibling) that EXISTS on disk. The dest FILE may not exist yet
            (`cp` creates it), so existence is asserted on the worktree ROOT, not
            the leaf — a non-existent `<prefix>-N-x` worktree tree fails because
            its root dir does not exist, while a legit sync INTO an existing
            worktree passes.
    """
    toks = re.findall(r'(/[^\s"\';<>|&]+)', command)
    if not toks:
        return False
    target = toks[-1]
    real = os.path.realpath(target)
    root = _resolved_worktree_root(real)
    if root is None:
        return False
    return os.path.isdir(root)


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

    Per-worktree hooks/ deny (#1070):
      The per-worktree git dir's `hooks/` subdir is the only execute-at-git-time
      surface here — git runs `<gitdir>/hooks/pre-commit` (etc.) inside the git
      subprocess, INVISIBLE to this PreToolUse hook. A trusted back-link would
      otherwise exempt that dir, letting an agent plant an executable pre-commit
      and gain code-exec at the next git op. So `<gitdir>/hooks` (and anything
      under it) is denied BEFORE the trust-return block, gating BOTH return-True
      sites with one guard. The check runs on `real` (already realpath'd by the
      caller `is_allowed`), so symlink/`..` forms normalize first. The anchor is
      the exact `gitdir + "/hooks"`, not a loose `'/hooks/'` substring, so
      `refs/…`, `logs/…`, and rebase/merge state writes are unaffected.
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
    hooks_dir = gitdir + "/hooks"
    if real == hooks_dir or real.startswith(hooks_dir + "/"):
        return False  # never exempt per-worktree hooks/ → kills pre-commit code-exec (#1070)
    for root in ALLOWED_ROOTS:
        if pointer == root or pointer.startswith(root + os.sep):
            return True
    if WORKTREE_PATTERN.match(pointer):
        return True
    return False


def _protected_write_context(command: str) -> bool:
    """Return True ONLY if a protected control-file appears in a WRITE/MODIFY position.

    Write positions covered:
    - redirect target: ``>``, ``>>``, ``>|`` (optionally fd-prefixed)
    - in-place / overwrite mutators: ``sed -i``, ``perl -i``, ``tee``,
      ``chmod``, ``chown``
    - ``dd of=<protected>`` keyword form
    - ``truncate`` with a protected positional
    - copy/move DESTINATION (last positional of cp/mv/install/rsync/ln)

    Reads/references (cat, grep, ls, find, cp <protected> <dest>) have no
    write position and return False — the guard no longer fires on them.

    IMPORTANT: the cp/mv/install/rsync/ln destination detection tokenizes
    RELATIVE positionals, NOT just ``/``-anchored absolute tokens.  Reusing
    ``_command_has_worktree_dest``'s ``re.findall(r'(/[^\\s\\"\\';|&]+)')``
    regex would silently miss ``cp evil.json .claude/settings.json`` (relative
    dest).  See Task-3 mandate in the approved plan for issue #1136.
    (Bug 2 fix — issue #1136.)
    """

    def _has_protected_token() -> bool:
        for pat in PROTECTED_CMD_PATTERNS:
            if re.search(pat, command):
                return True
        return False

    # 1. Redirect target: optional fd digit + >, >>, >| + optional spaces
    #    + protected path.  Covers: `echo x > .claude/settings.json`,
    #    `printf x > /abs/.claude/settings.json`, etc.
    if re.search(
        r"\d*>>?\|?\s*(?:\./)?(?:[^\s'\";<>|&]*/)?\.claude/",
        command,
    ):
        return True

    # 2. In-place / overwrite mutators that act on a named argument.
    #    tee writes its stdin to the named file; sed/perl -i edits in place.
    if re.search(
        r"\b(?:tee|sed\s+(?:-\w*i|--in-place)|perl\s+-\w*i|chmod|chown)\b",
        command,
    ):
        if _has_protected_token():
            return True

    # 3. dd of=<protected>
    if re.search(r"\bdd\b", command) and re.search(
        r"\bof=(?:\./)?(?:[^\s'\";<>|&]*/)?\.claude/",
        command,
    ):
        return True

    # 4. truncate with a protected positional.
    if re.search(r"\btruncate\b", command) and _has_protected_token():
        return True

    # 5. Copy/move DESTINATION — cp/mv/install/rsync/ln.
    #    Two destination shapes are recognized:
    #    (a) dest-via-flag (Bug 1138.1) — `-t <dir>` / `-t<dir>` /
    #        `--target-directory[=| ]<dir>` for the cp/mv/install/ln family
    #        ONLY (NOT rsync, whose `-t` is `--times`, not a target directory).
    #        The real write destination lives in a FLAG (or its argument), which
    #        the last-positional scan would otherwise drop. When such a
    #        `flag_dest` is present it IS the destination (all positionals become
    #        sources), so ONLY `flag_dest` is checked — a protected file used as
    #        a cp SOURCE alongside a safe `-t` dest therefore stays allowed.
    #    (b) last positional (when no flag_dest) — byte-for-byte the #1136
    #        check. Relative-aware tokenization so that a relative protected
    #        dest (`.claude/settings.json`) is caught, not just absolute ones.
    if re.search(r"\b(?:cp|mv|install|rsync|ln)\b", command):
        _CMD_NAMES = {"cp", "mv", "install", "rsync", "ln", "sudo", "env", "command"}
        raw_toks = re.split(r"[\s;|&<>]+", command)
        flag_dest = None
        if re.search(r"\b(?:cp|mv|install|ln)\b", command):
            stripped = [t.strip("\"'") for t in raw_toks]
            for idx, tok in enumerate(stripped):
                if not tok:
                    continue
                if tok in ("-t", "--target-directory"):
                    nxt = next((s for s in stripped[idx + 1:] if s), None)
                    if nxt is not None:
                        flag_dest = nxt
                    break
                if tok.startswith("--target-directory="):
                    flag_dest = tok.split("=", 1)[1]
                    break
                if tok.startswith("-t") and not tok.startswith("--") and len(tok) > 2:
                    flag_dest = tok[2:]
                    break
        if flag_dest is not None:
            for pat in PROTECTED_CMD_PATTERNS:
                if re.search(pat, flag_dest):
                    return True
        else:
            positionals = []
            for tok in raw_toks:
                tok = tok.strip("\"'")
                if not tok:
                    continue
                if re.match(r"^-", tok):      # flags: -r, -f, --flag, etc.
                    continue
                if tok in _CMD_NAMES:
                    continue
                positionals.append(tok)
            if positionals:
                dest = positionals[-1]
                for pat in PROTECTED_CMD_PATTERNS:
                    if re.search(pat, dest):
                        return True

    # 6. Interpreter inline-script write (Bug 1138.2). An inline interpreter
    #    body (`python -c`, `python3 -c`, `node -e`, `perl -e`/`-pe`/`-ne`,
    #    `ruby -e`, `--eval`) can write a protected control file without ever
    #    naming it as a shell-level positional, so every scan above is blind to
    #    it. Key on the (interpreter-inline ∧ protected-token) signal: when an
    #    interpreter word is followed (across leading flags only) by an
    #    inline-eval flag AND a protected control-file token appears anywhere in
    #    the command, BLOCK. The match is ANCHORED to the inline-eval flag so a
    #    real script run that merely passes args (`python script.py -e foo`) has
    #    a POSITIONAL, not a flag, after the interpreter and is therefore NOT
    #    treated as an inline eval — it stays allowed. Residual porosity (a path
    #    built dynamically inside the body, or hidden in an external script
    #    file) is unchanged — the same #964 limit as the boundary check.
    if re.search(
        r"\b(?:python[0-9.]*|node|perl|ruby)\b(?:\s+-\S+)*?"
        r"\s+(?:-[A-Za-z]*[ceE]\b|--eval\b)",
        command,
    ) and _has_protected_token():
        return True

    return False


def is_allowed(path: str) -> bool:
    if not path:
        return True
    real = _resolve(path)
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

# Check for protected file edits — Write/Edit only.  Reads (Read/Glob/Grep)
# are legitimately allowed to name protected paths; the inline-disarm threat
# (#964) is covered for Bash by the write-aware command-string scan below.
# (Bug 2 fix — gating on actual write tools — issue #1136.)
if tool_name in ("Write", "Edit"):
    for path in paths:
        if is_protected(path):
            print(
                f"BLOCKED: cannot modify protected file: {path}",
                file=sys.stderr,
            )
            sys.exit(2)

# Bash command-string protected-token scan (#964): the absolute+exists
# extractor never sees RELATIVE disarm targets, so scan the raw command for
# protected control-file references.  Now gated on _protected_write_context
# so reads/references (cat, grep, ls, cp-source) are no longer blocked —
# only genuine write positions (redirects, in-place mutators, copy/move
# destinations, dd of=, truncate) trigger the block.  Skipped when the
# command names an existing worktree destination (the legit sync carve-out).
# (Bug 2 fix — issue #1136.)
#
# _protected_write_context is THE authoritative write-position detector: every
# branch that returns True has already matched a protected control file in a
# real write position (its cp/mv/install/ln branch isolates the `-t<dir>` /
# `--target-directory=` destination and matches THAT token against
# PROTECTED_CMD_PATTERNS directly). So we block on its result alone. The prior
# code re-scanned the FULL command string against PROTECTED_CMD_PATTERNS as a
# second gate — but that anchor `(?:^|[\s=>'"|&;(])` needs a delimiter before
# `.claude/`, which the NO-SPACE glued `-t.claude/hooks/` form does NOT have
# (the protected token is preceded by the `t` of `-t`), so the re-scan failed
# and the glued disarm slipped through to exit 0 (#1138). The re-scan was
# strictly redundant for every non-glued write position (each already carries a
# delimiter-anchored protected token), so dropping it is byte-for-byte for those
# paths and closes ONLY the glued-dest gap. (Bug 1138 re-tighten — issue #1138.)
if tool_name == "Bash":
    command = tool_input.get("command", "")
    if not _command_has_worktree_dest(command) and _protected_write_context(command):
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
