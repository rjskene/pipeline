"""
PreToolUse hook — restricts file operations to the project directory and ~/.claude/.
Exits 2 (blocked) if a tool targets a path outside those boundaries.

Issue #1188 — cd-escape gate: the Bash command-string extractor below only
lifts `/`-anchored ABSOLUTE tokens, so it has no model of the shell working
directory. `cd <anywhere> && <write to a plain relative path>` therefore left
the project boundary with nothing to extract — the string is benign, the
SHELL is what makes it point outside (e.g. `cd ../../.. && mkdir -p
volumes/x`). The gate at the tail of the Bash flow resolves a COMMAND-POSITION
leading `cd` operand against the event-payload `cwd` (only when that is
itself in-boundary — otherwise PROJECT_DIR) and blocks the whole command when
the resolved target lands outside the boundary. `is_allowed()` is reused
verbatim as the comparator, so the `/tmp` carve-out, `~/.claude`,
sibling/nested worktrees, and the Windows/MSYS `_canon` branch (#1153) are
inherited for free. Operand grammar: `cd -` (needs OLDPWD) and any
`$VAR`/backtick/glob-bearing operand are unresolvable without shell state and
fail open; bare `cd` and `cd --` (nothing following) are bash's `cd $HOME`;
`--` is treated as POSIX end-of-options, not an operand. `cd` is detected only
after `^`, `;`, `&`, `|`, `(`, `{` — deliberately NOT after a newline (heredoc
bodies and later lines of a multi-line script are script TEXT, not a command
being run — including `\n` would turn ordinary script-authoring into a new
over-block class). The quote chars are likewise NOT in that class, so a
`cd` that merely appears inside a quoted word (`echo "cd .."`,
`ssh host "cd …"`) is never a command position — including one in the
#1135/#1151 false-positive family.

Issue #1190 — quoted-region masking: that lookbehind class had no notion of
quoting, so a separator sitting INSIDE a quoted string still opened a command
position and any change-directory word after it was resolved for real. Ordinary
quoted PROSE that merely DESCRIBES traversal (a `git commit -m` subject, a
`printf` payload, a variable assignment) was therefore blocked — observed live
minutes after #1188 merged. `_iter_cd_targets` now scans a LENGTH-PRESERVING
masked copy (`_mask_quoted_regions`) in which every character strictly inside a
quoted region is neutralised while the quote DELIMITERS and newlines survive,
and slices each operand from the ORIGINAL string via the match span — so the
dequote / `cd -` skip / `$`-backtick-glob fail-open all keep seeing real text.
Masking can only REMOVE command positions that are provably inside a quoted
region; every position outside quotes is byte-for-byte unchanged, so the change
is strictly additive to the #1188 escape set. An UNTERMINATED quote fails
CLOSED (the raw command is scanned instead — exactly #1188's behavior, never
fewer blocks); masking to end-of-string would be a one-character bypass. The
mask is scoped to this gate ONLY and must never reach `extract_paths()`'s
scrubbed string, whose token-boundary class deliberately INCLUDES the quote
chars — masking that would blind the extractor to every quoted absolute
out-of-boundary token (`cat "/etc/passwd"`).

Issue #1192 — nested shell strings, heredoc bodies, ANSI-C quoting. Three
residuals surfaced by the #1191 differential drive, resolved as follows.

IN scope (scanned/masked): `$'…'` ANSI-C regions are masked in
`_mask_quoted_regions` exactly like any other quoted region (a backslash
escapes the following char, per POSIX `$'…'` semantics, unlike a plain
`'…'` region where a backslash is literal). Heredoc BODIES are masked as
stdin DATA — via `_mask_heredoc_bodies` — in both the cd gate and the
protected-write scan, EXCEPT when the owning pipeline segment's COMMAND WORD
(`_segment_command_word`, never a line-wide search — see that function's
docstring for why) resolves to a known interpreter (`bash`/`sh`/`zsh`/`dash`/
`ksh`/`python*`/`node`/`perl`/`ruby`, reached through `env`/`nohup`/`sudo`-
style wrapper words): such a body IS executed, so it stays scanned, fail
closed. ONE level of a recognized `<shell> -c '<fully quoted string>'` is
scanned by `_NESTED_SHELL_RE` via a `depth`-capped recursive call into
`_iter_cd_targets`, so the inner string inherits quote masking, heredoc
masking, the `cd -` skip and the `$`/backtick/glob fail-open for free; the
recognizer runs over the MASKED `scan`, not the raw command, so quoted prose
that merely NAMES the shape (a commit message, a `gh issue comment --body`)
is never mistaken for a command position — that would be the #1190
over-block class verbatim.

OUT of scope, stated plainly: depth-2+ nesting (`bash -c "bash -c '…'"`) —
a hard cap, not unbounded recursion, per #1188's explicit non-goal below; a
non-`-c` remote-shell string (`ssh host "cd …"`) — deliberately preserved as
the #1135/#1151 false-positive family, since requiring a `c`-bearing flag on
a known shell word is what keeps it open; a heredoc body later `eval`'d or
piped to a shell out-of-line; a heredoc whose delimiter coincides with an
ordinary body line by coincidence; anything requiring real shell emulation.

Issue #1194 — wrapper ARITY, arithmetic `<<`, and POSIX `--`. Three residuals
the #1192 heredoc mask and nested-shell recognizer left behind, surfaced by
the differential drive on PR #1193.

IN scope (scanned/masked, or corrected): `_segment_command_word`'s walk now
carries a per-wrapper ARITY model (`_WRAPPER_ARG_OPTS` — options that consume
a SEPARATE following token; `_WRAPPER_POSITIONALS` — positionals consumed
before the command word, `timeout: 1`, every other wrapper 0), so a
wrapper's own argument — positional (`timeout 300 bash <<EOF`) or a separate
option argument (`sudo -u root bash <<EOF`, `env -u FOO bash <<EOF`) — is
stepped over instead of being mistaken for the command word; `nice` is added
to `_WRAPPER_WORDS` (previously absent entirely). Neither consume-arm may
swallow a token that basenames to an `_INTERP_WORD_RE` word (the
INTERPRETER GUARD) — an interpreter is never a `timeout` duration, a `sudo`
username, or an `env -S` non-command argument, so `env -S bash <<EOF`,
`timeout --preserve-status bash <<EOF`, `sudo -u bash id <<EOF`, and
`stdbuf -o bash <<EOF` all still resolve to `bash` and stay scanned. A new
`_mask_arith_regions` blanks the interior of `$(( … ))` (any position) and of
command-position `(( … ))` (start of line, after `;&|(){`, or after
`if`/`while`/`until`/`elif`/`then`/`do`) before the heredoc-operator probe
runs, so an arithmetic left-shift (`echo $((x << y))`, `((x << y))`) is never
mistaken for a heredoc operator opening a phantom body. `_NESTED_SHELL_RE`'s
flag group now requires a LETTER immediately after its dashes, so a bare
POSIX `--` end-of-options marker (`bash -- -c "cd …"`) is no longer absorbed
as a vacuous flag with `-c` still matching — `--posix`, `--norc`, `-lc`, and
`-x -c` are unaffected.

OUT of scope, stated plainly:
  - An unknown arg-taking option on a ZERO-positional wrapper still
    terminates the walk on its argument: `sudo --made-up X bash <<EOF` and
    `env --made-up X bash <<EOF` stay allowed. This does NOT hold for
    `timeout` — its 1-positional budget absorbs `X`, so
    `timeout --made-up X bash <<EOF` BLOCKS.
  - Wrapper words outside `_WRAPPER_WORDS` are unmodelled: `flock`,
    `ionice`, `setsid`, `unbuffer`, `chrt`, `taskset`, `doas`
    (`flock /tmp/l bash <<EOF` stays allowed).
  - `xargs` is DELIBERATELY excluded — its stdin is the argument list, not
    the child's script, so a heredoc under `xargs bash …` genuinely is data.
  - An UNBALANCED arithmetic region fails OPEN: `echo $((a << b` followed by
    a `cd` on the next line stays allowed (the phantom heredoc still opens).
    Deliberate — no guess at where an unbalanced region ends, matching this
    hook's existing fail-open doctrine for unresolvable state.
  - A non-command-position `((` is not masked — `for ((i=0;i<n;i++))` and
    any other unanchored `((`.
  - Unquoted prose naming the nested-shell shape over-blocks:
    `echo bash -c "cd …"` stays blocked. Documented, not fixed — a
    command-position anchor on `_NESTED_SHELL_RE` was measured to drop SEVEN
    wrapper-reached shapes (`xargs`/`find -exec`/`ssh host`/`timeout`/`sudo`/
    `env`/`nohup` + `bash -c`) from blocked to allowed, four of them the very
    shapes the wrapper-arity fix above exists to protect — trading real
    under-blocks for one contrived over-block is the wrong direction for a
    containment tripwire.
  - `((cat <<EOF) && (true))` over-blocks (accepted, block-direction — a real
    heredoc operator inside an arithmetic-shaped grouping is masked away).
  - `timeout 300 python script.py <<EOF` now resolves to `python` and its
    body is scanned — identical in kind to the pre-existing unwrapped
    `python script.py <<EOF` behavior, not a new class.
  - The arity tables are a maintenance surface: a wrapper option added
    upstream that this hook does not yet know about silently reverts to the
    old under-block for that one form.
  - Unchanged #1192 OUT items (above) still apply: depth-2+ nesting, a
    non-`-c` remote-shell string, a herestring, an out-of-line `eval`'d
    heredoc body, a delimiter that coincides with an ordinary body line, and
    anything requiring real shell emulation.

Explicit non-goals, same as the rest of this hook's "best-effort" scope: no
shell emulation, no `pushd`/subshell/`$VAR` tracking, and an in-project `cd`
does not re-anchor the absolute-token scan.
"""
import os
import posixpath
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _pipeline_config import read as _read_config  # noqa: E402
from subagent_log_utils import read_event_stdin  # noqa: E402

data = read_event_stdin()
tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input", {})
# Event-payload `cwd` (issue #1188) — the harness-supplied shell working
# directory at invocation time. Consulted ONLY by the cd-escape gate below
# (never by `_resolve`/`is_allowed` generally) as the anchor for a relative
# `cd` operand.
EVENT_CWD = data.get("cwd") or ""

PROJECT_DIR = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()))
CLAUDE_HOME = os.path.realpath(os.path.expanduser("~/.claude"))

# Raw (pre-realpath) project/home roots — used ONLY to build the Windows/MSYS
# canonical comparison keys below. os.path.realpath() mangles a Windows-shaped
# root on POSIX (e.g. realpath("C:\\Users\\u\\repo") -> "<cwd>/C:\Users\u\repo";
# realpath("/c/...") does not map to a drive letter at all), so the Windows
# canonical key MUST be derived from the raw env value, never the realpath'd
# one. (Issue #1153.)
_RAW_PROJECT_DIR = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
_RAW_CLAUDE_HOME = os.path.expanduser("~/.claude")


def _looks_windows(p: str) -> bool:
    """True if `p` is shaped like a Windows or MSYS path.

    Matches a leading drive letter (``C:\\...`` / ``C:/...``), an MSYS drive
    prefix (``/c/...``), or any backslash appearing anywhere in the string.
    The MSYS ``^/[A-Za-z]/`` shape deliberately requires a full ``/x/``
    two-segment prefix, so it does NOT match bare branch-name-shaped
    fragments like ``/rerate-after-edits`` or ``/Reject`` (#353). (Issue
    #1153.)
    """
    if not p:
        return False
    if re.match(r"^[A-Za-z]:[\\/]", p):
        return True
    if re.match(r"^/[A-Za-z]/", p):
        return True
    if "\\" in p:
        return True
    return False


def _canon(p: str) -> str:
    """Canonicalize a Windows/MSYS-shaped path string for boundary comparison.

    A pure string transform — never touches the filesystem (os.path.realpath
    mangles Windows-shaped input on POSIX, see `_looks_windows` docstring):
    backslashes become forward slashes, an MSYS drive prefix ``/x/...``
    becomes ``x:/...``, `posixpath.normpath` collapses ``..``/``.`` segments
    (preserving the ``..``-escape tripwire), then the result is casefolded
    (NTFS is case-insensitive). Safe to call on POSIX-shaped input too — used
    below to build the project/home canonical root keys. (Issue #1153.)
    """
    q = p.replace("\\", "/")
    m = re.match(r"^/([A-Za-z])/(.*)$", q)
    if m:
        q = f"{m.group(1)}:/{m.group(2)}"
    q = posixpath.normpath(q)
    return q.casefold()


# Canonical comparison keys for the project root and ~/.claude, built from the
# RAW (pre-realpath) values so a Windows-shaped CLAUDE_PROJECT_DIR canonicalizes
# to a real drive-letter key instead of a realpath-mangled one. (Issue #1153.)
_ALLOWED_CANON_KEYS = [_canon(_RAW_PROJECT_DIR), _canon(_RAW_CLAUDE_HOME)]


def _is_session_scratchpad(canon_key: str) -> bool:
    """True if a Windows-canonicalized path key falls under the Claude session
    scratchpad root.

    The harness-advertised session scratchpad lives at
    ``.../Temp/claude/<project-slug>/<session-id>/scratchpad/...`` (per the
    Claude Code system prompt). Scoped narrowly to the ``Temp/claude/``
    subtree — NOT all of Temp — a deliberate, bounded widen of the boundary to
    Claude's own session temp root, not a general Temp allowlist. (Issue
    #1153, fingerprint 1.)
    """
    return "/temp/claude/" in canon_key


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

    Issue #1192: `command` is rebound to its heredoc-body-masked copy as the
    very first statement, so every branch below (and the nested
    `_has_protected_token()`, which closes over the same name) sees the
    masked copy — a protected-looking token that merely appears inside a
    heredoc BODY (prose or HTML naming `.claude/hooks/`) no longer trips this
    guard, while a real redirect into a protected file on the heredoc's own
    OPERATOR line still does (that line is never masked). Safe to rebind:
    this function only ever whole-string `re.search`s `command`, it never
    slices a span computed against it.
    """
    command = _mask_heredoc_bodies(command)

    def _has_protected_token() -> bool:
        for pat in PROTECTED_CMD_PATTERNS:
            if re.search(pat, command):
                return True
        return False

    # 1. Redirect target: optional fd digit + >, >>, >| + optional spaces +
    #    optional quote + protected path.  Covers: `echo x > .claude/settings.json`,
    #    `printf x > /abs/.claude/settings.json`, etc.
    #
    #    Issue #1212: isolate the redirect TARGET token and match it against
    #    PROTECTED_PATTERNS (the path-shaped list) instead of returning True
    #    on the bare `.claude/` prefix — the prior version blocked EVERY
    #    redirect into a `.claude/` subtree, including the gitignored, inert
    #    `.claude/scratch/` dir. The optional leading `['"]?` also closes a
    #    pre-existing bypass: a QUOTED redirect target (`echo x >
    #    ".claude/settings.json"`) previously slipped past the bare-prefix
    #    match entirely (nothing in the old prefix group could span the
    #    opening quote).
    #
    #    The TARGET-tail class additionally excludes `(`, `)` and a backtick:
    #    two of the PROTECTED_PATTERNS are `$`-anchored (`…/settings\.json$`),
    #    so a trailing subshell / command-substitution delimiter swallowed into
    #    the captured token would defeat the anchor and let
    #    `(echo x > .claude/settings.json)` through — a shape the pre-#1212
    #    bare-prefix match blocked.  Those chars can never be part of the
    #    redirect target word anyway.
    for _m in re.finditer(
        r"""\d*>>?\|?\s*['"]?((?:\./)?(?:[^\s'\";<>|&]*/)?\.claude/[^\s'\";<>|&()`]*)""",
        command,
    ):
        _target = _m.group(1)
        for _p in PROTECTED_PATTERNS:
            if re.search(_p, _target):
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
    # Windows/MSYS-shaped paths bypass the POSIX realpath/relative-join branch
    # entirely: os.path.isabs("C:\\...") is False on POSIX, so `_resolve` would
    # otherwise join it AS RELATIVE under PROJECT_DIR — landing in-tree
    # regardless of whether the real Windows path is in- or out-of-tree (a
    # latent over-allow). Instead compare a canonical string key: exact match
    # or a proper sub-path of the project/home root, or the Claude session
    # scratchpad. Pure-POSIX paths never take this branch, so Linux behavior
    # (symlink/`..`-escape/`//`-collapse/worktree handling below) is
    # byte-for-byte unchanged. (Issue #1153.)
    if _looks_windows(path):
        k = _canon(path)
        for key in _ALLOWED_CANON_KEYS:
            if k == key or k.startswith(key + "/"):
                return True
        if _is_session_scratchpad(k):
            return True
        return False
    real = _resolve(path)
    for root in ALLOWED_ROOTS:
        if real == root or real.startswith(root + os.sep):
            return True
    if WORKTREE_PATTERN.match(real):
        return True
    if _worktree_pointer_allows(real):
        return True
    return False


def _cd_anchor() -> str:
    """Resolve the anchor for a relative `cd` operand (issue #1188).

    Prefers the event-payload `cwd` (EVENT_CWD, harness-supplied), but ONLY
    when it is itself in-boundary (`is_allowed(EVENT_CWD)`) — falling back on
    an out-of-project payload cwd would resurrect the #1136 over-block class:
    an ordinary in-repo `cd sub` could resolve outside if the payload cwd were
    an untrusted outer-terminal path. Falls back to PROJECT_DIR otherwise,
    matching `_resolve`'s existing anchor.
    """
    if EVENT_CWD and is_allowed(EVENT_CWD):
        return os.path.realpath(EVENT_CWD)
    return PROJECT_DIR


# Command-position leading `cd` target (issue #1188). Fires only when `cd`
# starts the command, or immediately follows a command separator (`;`, `&`,
# `|`) or a subshell/group opener (`(`, `{`) — deliberately NOT after a
# newline (see module docstring). The quote chars are not in the class either,
# so `echo "cd .."` / `ssh host "cd …"` never match (that would re-open
# #1135/#1151); and per #1190 this regex is run over a quote-MASKED copy of the
# command (see `_mask_quoted_regions`), so a separator INSIDE a quoted region
# cannot open a command position at all.
#
# Flags group is `-{1,2}[A-Za-z]+` — one-or-more letters, NOT `[A-Za-z]*` —
# so `cd -` is never consumed as a flag (with `*` the group would eat the
# bare `-`, leaving operand None and misrouting `cd -` into the bare-`cd` `~`
# branch). `--` is a SEPARATE leading alternative (POSIX end-of-options): the
# word after it is the operand, not swallowed as a flag; `cd -- ../../..`
# must still yield the real target.
_CD_RE = re.compile(
    r"(?:^|(?<=[;&|({]))\s*cd(?=\s|$)"
    r"((?:\s+--(?=\s|$)|\s+-{1,2}[A-Za-z]+)*)"
    r"(?:\s+(\"[^\"]*\"|'[^']*'|[^\s;&|<>]+))?"
)


# Neutral filler for masked characters (issue #1190). Any char that is not a
# `_CD_RE` metacharacter works; `x` is a plain word char, so a masked region
# reads as ordinary text to the scan and can never open a command position.
_MASK_CHAR = "x"


def _mask_quoted_regions(command: str):
    """Return a length-preserving copy of `command` with quoted interiors masked.

    Issue #1190. Every character strictly INSIDE a single- or double-quoted
    region is replaced with `_MASK_CHAR`; the quote DELIMITERS themselves and
    any newline are preserved verbatim. Length preservation is load-bearing —
    it is what makes a `_CD_RE` match span computed on the masked copy valid as
    a slice into the ORIGINAL string. Preserving the delimiters is likewise
    load-bearing: `_CD_RE`'s `"[^"]*"` / `'[^']*'` operand alternatives must
    still match a quoted `cd` TARGET (#1188 case 5).

    Scanner rules — deliberately not a shell parser (see module docstring).
    Outside a region: `\\` escapes the next character, so `don\\'t` does NOT
    open a region; an unescaped `"` or `'` opens one. Inside `"…"`: `\\X` masks
    BOTH characters, so `\\"` does not close the region, and a `'` is ordinary
    text. Inside `'…'`: only `'` closes, and a backslash is literal (POSIX).

    Returns None when the scan ends still inside a region — an unterminated
    quote FAILS CLOSED, and the caller scans the raw command instead (exactly
    #1188's behavior, never fewer blocks). Masking such a string to its end
    would hand over a one-character bypass.
    """
    out = []
    quote = ""
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if not quote:
            if ch == "\\":
                # Escapes the next char, whatever it is — including a quote,
                # which therefore does NOT open a region.
                out.append(ch)
                if i + 1 < n:
                    out.append(command[i + 1])
                    i += 2
                else:
                    i += 1
                continue
            if ch == "$" and command[i + 1:i + 2] == "'":
                # ANSI-C opener (issue #1192). Emit both chars verbatim and
                # enter the two-char "$'" quote mode below.
                out.append(ch)
                out.append(command[i + 1])
                quote = "$'"
                i += 2
                continue
            if ch in "\"'":
                quote = ch
            out.append(ch)
            i += 1
            continue
        # Inside a quoted region.
        if quote == "$'" and ch == "\\":
            # ANSI-C region: a backslash escapes the next char (mirrors the
            # double-quote arm below, including newline preservation).
            out.append(_MASK_CHAR)
            if i + 1 < n:
                nxt = command[i + 1]
                out.append("\n" if nxt == "\n" else _MASK_CHAR)
                i += 2
            else:
                i += 1
            continue
        if quote == "$'" and ch == "'":
            # Closes the ANSI-C region. The generic `ch == quote` test below
            # can never fire here since `quote` is the two-char "$'".
            quote = ""
            out.append(ch)
            i += 1
            continue
        if quote == '"' and ch == "\\":
            out.append(_MASK_CHAR)
            if i + 1 < n:
                nxt = command[i + 1]
                out.append("\n" if nxt == "\n" else _MASK_CHAR)
                i += 2
            else:
                i += 1
            continue
        if ch == quote:
            quote = ""
            out.append(ch)
            i += 1
            continue
        out.append("\n" if ch == "\n" else _MASK_CHAR)
        i += 1
    if quote:
        return None
    return "".join(out)


# Heredoc-body masking (issue #1192). `_HEREDOC_OP_RE`'s `(?<!<)...(?!<)`
# lookaround excludes a `<<<` herestring (which opens no body at all) from
# ever matching as a heredoc operator — a plain `<<(?!<)` still matches at
# offset 1 of `<<<`. Group 1 is the `-` of a `<<-` tab-stripping form; group 2
# is the optional quote char around the delimiter word (its own group so the
# `\2` backreference can require a matching close quote); group 3 is the
# delimiter word itself.
_HEREDOC_OP_RE = re.compile(r"(?<!<)<<(?!<)(-?)\s*([\"']?)([A-Za-z_][A-Za-z0-9_]*)\2")

# A heredoc body owned by one of these command words IS executed (fed to an
# interpreter on stdin), not merely stored as data — so it stays scanned,
# fail closed.
_INTERP_WORD_RE = re.compile(r"^(?:bash|sh|zsh|dash|ksh|python[0-9.]*|node|perl|ruby)$")

# Wrapper words that pass an interpreter through unchanged as far as the
# heredoc carve-out is concerned (`env FOO=1 bash <<EOF`, `sudo bash <<EOF`).
# `nice` (issue #1194) was previously absent entirely.
_WRAPPER_WORDS = {
    "env", "nohup", "command", "sudo", "timeout", "stdbuf", "exec", "time",
    "nice",
}

# Issue #1194 — per-wrapper arity model. Each wrapper's OPTIONS that consume a
# SEPARATE following token (as opposed to a glued spelling like `-oL`/`-n5`/
# `--unset=FOO`, which the exact-match compare in `_segment_command_word`
# below never touches). A wrapper absent from this mapping, or an option not
# listed for its wrapper, is treated as taking no separate argument.
_WRAPPER_ARG_OPTS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "sudo": {
        "-u", "--user", "-g", "--group", "-p", "--prompt",
        "-C", "--close-from", "-D", "--chdir", "-R", "--chroot",
        "-h", "--host", "-U", "--other-user", "-r", "--role",
        "-t", "--type", "-T", "--command-timeout",
    },
    "timeout": {"-k", "--kill-after", "-s", "--signal"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "nice": {"-n", "--adjustment"},
    "exec": {"-a"},
    "time": {"-o", "--output", "-f", "--format"},
    "nohup": set(),
    "command": set(),
}

# Positionals a wrapper consumes BEFORE its command word (`timeout <duration>
# <command>`). Every wrapper not listed here takes zero.
_WRAPPER_POSITIONALS = {"timeout": 1}

# Pipeline-segment separator class (command / pipeline segments) used to
# isolate the LAST segment of a line before resolving its command word
# (`echo x | bash <<EOF` must resolve to `bash`, the segment that owns the
# heredoc operator, not `echo`).
_SEG_SPLIT_RE = re.compile(r"\|\||&&|[;&|(){]")


def _basename_word(tok: str) -> str:
    """Dequote-strip and basename a raw whitespace token (`"bash` -> `bash`,
    `/bin/bash` -> `bash`). Shared by `_segment_command_word`'s wrapper-word
    check and its interpreter guard so both see the same normalized word.
    """
    return tok.strip("\"'").rsplit("/", 1)[-1]


def _segment_command_word(prefix: str) -> str:
    """Return the resolved command word of the LAST pipeline segment in `prefix`.

    Used by `_mask_heredoc_bodies` to decide whether a heredoc body is DATA
    (masked) or an interpreter's stdin script (left scanned). Splits `prefix`
    on `_SEG_SPLIT_RE` and takes the LAST segment, so `echo x | bash <<EOF`
    resolves relative to `bash`, not `echo`. Within that segment, walks
    whitespace tokens left to right, skipping `NAME=value` assignments.

    Issue #1194 — per-wrapper ARITY walk, replacing the old "skip every
    `-`-leading flag, skip every wrapper word" loop. A wrapper's argument can
    be POSITIONAL (`timeout 300 bash`) or a separate OPTION argument
    (`sudo -u root bash`, `env -u FOO bash`) — either shape used to leave the
    walk terminating on the wrapper's own argument instead of the wrapped
    interpreter, an under-block. The walk now tracks the MOST RECENTLY SEEN
    wrapper and a pending positional budget (`_WRAPPER_POSITIONALS`, default
    0), consulting `_WRAPPER_ARG_OPTS[wrapper]` to decide whether a
    `-`-leading token consumes the NEXT token too. The option-argument compare
    is EXACT (`tok in _WRAPPER_ARG_OPTS.get(wrapper, ())`), never a prefix
    test — that is what keeps the glued forms (`-oL`, `-n5`, `-k5`,
    `--unset=FOO`, `nice`'s bare `-5` adjustment) from wrongly eating their
    successor.

    The INTERPRETER GUARD (evaluator gap, issuecomment-5127926105): neither
    consume-arm above is allowed to swallow a token that basenames to an
    `_INTERP_WORD_RE` word. An interpreter is never a `timeout` duration, a
    `sudo` username, or an `env -S` non-command argument — `env -S bash`
    genuinely execs bash, and `timeout --preserve-status bash` has no
    duration at all. Without the guard the arity walk is NOT monotone: the
    token it newly steps over can BE the interpreter, silently turning a
    block into an allow (`env -S bash <<EOF`, `timeout --preserve-status bash
    <<EOF`, `sudo -u bash id <<EOF`, `stdbuf -o bash <<EOF` all regress to
    exit 0 without it). With the guard, the walk only ever skips a
    NON-interpreter token, so a word this function would have returned before
    is still returned — new blocks only, never new allows (measured 0
    block-to-allow flips across 7,857 driven rows + 578,808 in-process walk
    prefixes; see issuecomment-5128283503).

    On a POSITIONAL (non-`-`-leading) token: its basename is computed FIRST,
    then the pending-positional budget is decremented only when it is
    NON-interpreter (interpreter guard) and the budget is nonzero — otherwise
    the token is checked against `_WRAPPER_WORDS` (recording it as the new
    current wrapper and loading its budget) or, failing that, RETURNED as the
    resolved command word.

    Deliberately anchored on the COMMAND WORD, never a line-wide search: a
    line-wide `\\bsh\\b` search would match inside `script.sh` (the `.`
    supplies a word boundary) and wrongly exempt an everyday
    `cat > script.sh <<'EOF'` script-authoring heredoc from being masked.
    """
    segments = _SEG_SPLIT_RE.split(prefix)
    segment = segments[-1] if segments else prefix
    toks = segment.split()
    n = len(toks)
    wrapper = None
    pending_positionals = 0
    i = 0
    while i < n:
        tok = toks[i]
        i += 1
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok):
            continue
        if tok.startswith("-"):
            if (
                wrapper is not None
                and tok in _WRAPPER_ARG_OPTS.get(wrapper, ())
                and i < n
                and not _INTERP_WORD_RE.match(_basename_word(toks[i]))
            ):
                i += 1
            continue
        word = _basename_word(tok)
        if pending_positionals > 0 and not _INTERP_WORD_RE.match(word):
            pending_positionals -= 1
            continue
        if word in _WRAPPER_WORDS:
            wrapper = word
            pending_positionals = _WRAPPER_POSITIONALS.get(word, 0)
            continue
        return word
    return ""


# Issue #1194, shape 2 — arithmetic-expansion / arithmetic-command masking.
# `_HEREDOC_OP_RE` has no notion of arithmetic context, so a left-shift
# operator (`$((x << y))`, `((x << y))`) whose RHS happens to be an
# identifier satisfies the delimiter class `[A-Za-z_][A-Za-z0-9_]*` and is
# read as a real heredoc operator, opening a phantom body that masks every
# following line — a real UNDER-block. `_KEYWORD_BEFORE_ARITH_RE` recognizes
# the COMMAND-POSITION anchor for the bare `((` form only: start of line, one
# of `;&|(){`, or one of the compound-command keywords that can precede an
# arithmetic command (`if`/`while`/`until`/`elif`/`then`/`do`). `$((` is
# always eligible regardless of position (it is expansion syntax, not a
# command).
_KEYWORD_BEFORE_ARITH_RE = re.compile(
    r"(?:^|[;&|(){]|\b(?:if|while|until|elif|then|do))\s*$"
)


def _mask_arith_regions(line: str) -> str:
    """Return a length-preserving copy of `line` with arithmetic-expression
    interiors blanked, so `_HEREDOC_OP_RE` never mistakes an arithmetic `<<`
    (or any other character inside `$(( … ))` / command-position `(( … ))`)
    for a heredoc operator.

    Nesting-aware via paren-depth counting: scans left to right for a `((`
    token, decides eligibility (always for `$((`; command-position only,
    per `_KEYWORD_BEFORE_ARITH_RE`, for a bare `((`), then walks forward
    counting `(`/`)` until the two initial opens are balanced back to zero.
    On a match, the ENTIRE region — both delimiters and interior — is
    replaced with `_MASK_CHAR`, so a `<<` sitting anywhere inside (or
    straddling the parens themselves) cannot survive the probe.

    Fails OPEN on an unbalanced region: if no matching close is found, that
    `((` is left completely unmasked and the scan resumes just past it —
    only the unbalanced region is skipped, not the rest of the line, and not
    the whole mask operation. This is deliberate (issue #1194 OUT list): an
    unbalanced arithmetic region has no knowable end, so guessing where it
    stops is worse than leaving it scanned, matching this hook's existing
    fail-open doctrine for unresolvable state elsewhere (`cd -`, unsubstituted
    `$VAR`).

    Applied to the per-line heredoc-operator PROBE only (`_mask_heredoc_bodies`)
    — never to the line used for the delimiter slice or to the prefix
    `_segment_command_word` walks — so narrowing the operator recognizer can
    only recognize FEWER heredocs, i.e. mask FEWER bodies, i.e. scan MORE:
    the fail-closed direction. A non-command-position `((` (`for ((i=0;...))`)
    is intentionally left unmasked (OUT list) — the anchor is what keeps the
    masked surface to genuine arithmetic-command shapes.
    """
    if "((" not in line:
        return line
    out = list(line)
    n = len(line)
    i = 0
    while i < n - 1:
        if line[i] == "(" and line[i + 1] == "(":
            dollar = i > 0 and line[i - 1] == "$"
            eligible = dollar or bool(
                _KEYWORD_BEFORE_ARITH_RE.search(line[:i])
            )
            if eligible:
                depth = 2
                j = i + 2
                matched = False
                while j < n:
                    if line[j] == "(":
                        depth += 1
                    elif line[j] == ")":
                        depth -= 1
                        if depth == 0:
                            matched = True
                            break
                    j += 1
                if matched:
                    for k in range(i, j + 1):
                        if out[k] != "\n":
                            out[k] = _MASK_CHAR
                    i = j + 1
                    continue
            # Not eligible, or eligible but unbalanced (fail open): skip past
            # this "((" without masking so the outer scan cannot loop forever.
            i += 2
            continue
        i += 1
    return "".join(out)


def _mask_heredoc_bodies(command: str) -> str:
    """Return a length-preserving copy of `command` with heredoc BODIES masked.

    Issue #1192. A heredoc body is stdin DATA for the command that opened it,
    not a command being run — masking it out of the cd-scan and the
    protected-write scan removes the residual where an ordinary `;`-bearing
    body line (`echo a; cd ../..`) or a protected-looking body token (HTML or
    prose text merely NAMING `.claude/hooks/`) opened a false command
    position or a false protected-write match. The single exception is a body
    owned by an INTERPRETER command word (`bash`, `sh`, `python`, … reached
    through `env`/`sudo`-style wrapper words, per `_segment_command_word`):
    that body IS executed, so it stays scanned, fail CLOSED.

    Line-by-line algorithm. A line currently inside a pending heredoc body is
    BODY: if it equals the queued delimiter (leading tabs stripped first when
    the `<<-` form was used) it is the TERMINATOR — emitted verbatim, and the
    FIFO queue advances to the next pending delimiter (bash consumes multiple
    bodies opened on one operator line in left-to-right order); otherwise the
    whole line is replaced with `_MASK_CHAR` fill. A line NOT inside a
    pending body is an ordinary command line: emitted verbatim (so a real
    command position on the OPERATOR line itself, e.g. `cat <<EOF > s.txt; cd
    ..`, is unaffected), then probed for heredoc operators via a per-line
    quote PROBE (`_mask_quoted_regions(line)`, falling back to the raw line
    when that returns None — monotone, so probing can only find the SAME OR
    FEWER operators than a raw scan of the line, i.e. it cannot introduce a
    new class of missed operator) and `_HEREDOC_OP_RE.finditer` over that
    probe, so a `<<` sitting inside a quoted string on the line (`echo "a <<
    EOF"`) is not mistaken for a real operator. Each match's delimiter is
    read from the ORIGINAL line (the probe may have masked the delimiter's
    interior when it is quoted) via the match span. If the owning segment's
    command word resolves to a known interpreter, the body IS code: the
    pending-queue accumulation for this line stops immediately (`break`) and
    nothing from this operator onward is queued — so every following line up
    to the next already-open body (or end of command) is left UNMASKED,
    fail-closed, rather than silently truncating the return value (both masks
    must stay length-preserving for the span-slice contract `_iter_cd_targets`
    depends on). Otherwise every operator on the line queues its
    `(delimiter, dash)` pair.

    No heredoc operator anywhere in `command` is a byte-for-byte no-op. This
    function raises no exceptions — plain string operations only, since
    `_protected_write_context` (unlike the cd gate) has no `try/except`
    wrapper around it.
    """
    if "<<" not in command:
        return command
    lines = command.split("\n")
    out_lines = []
    queue: list[tuple[str, bool]] = []
    for line in lines:
        if queue:
            delimiter, dash = queue[0]
            content = line.lstrip("\t") if dash else line
            if content == delimiter:
                out_lines.append(line)
                queue.pop(0)
            else:
                out_lines.append(_MASK_CHAR * len(line))
            continue
        out_lines.append(line)
        probe = _mask_quoted_regions(line)
        if probe is None:
            probe = line
        probe = _mask_arith_regions(probe)
        for m in _HEREDOC_OP_RE.finditer(probe):
            dash = m.group(1) == "-"
            delimiter = line[m.start(3):m.end(3)]
            word = _segment_command_word(line[:m.start()])
            if _INTERP_WORD_RE.match(word):
                queue = []
                break
            queue.append((delimiter, dash))
    return "\n".join(out_lines)


# One level into a recognized `<shell> -c '<fully quoted string>'` (issue
# #1192). `\b(?:bash|sh|zsh|dash|ksh)\b` cannot match inside `ssh` — there is
# no word boundary between the two `s` characters — so a bare
# `ssh host "cd .."` (no `-c`) never matches; requiring the literal
# `c`-bearing flag is likewise what keeps `ssh -c <cipher>` and
# `git -c key=value` unaffected (neither `ssh` nor `git` is a shell word in
# the alternation, and a NON-`c` flag on a shell word, if any existed, would
# not match `-[A-Za-z]*c(?=\s)` either). The optional
# `(?:\s+-{1,2}[A-Za-z][A-Za-z-]*)*?` group absorbs any flags BEFORE the
# `-c`-bearing one (`bash -x -c '...'`); the `-c`-bearing flag itself may
# carry glued letters (`-lc`). Issue #1194, shape 3b: a flag must start with
# a LETTER after its dashes, so a bare POSIX `--` end-of-options marker no
# longer satisfies the flag class and gets absorbed into it — previously
# `[A-Za-z-]+` accepted a lone `-`, so `bash -- -c '...'` matched with `--`
# consumed as a (vacuous) flag and `-c` still recognized, even though after a
# real `--` bash reads `-c` as a script FILENAME and runs no `-c` string at
# all (an over-block). `--posix`, `--norc`, `-lc`, `-x -c` all still start
# with a letter right after their dashes and are unaffected. The operand
# alternatives `"[^"]*"` / `'[^']*'` are the same non-nesting approximation
# `_CD_RE` already uses for a quoted `cd` operand — a fully quoted argument is
# required, so an unterminated inner quote simply does not match (fail open,
# no guess at where the argument ends).
_NESTED_SHELL_RE = re.compile(
    r"\b(?:bash|sh|zsh|dash|ksh)\b(?:\s+-{1,2}[A-Za-z][A-Za-z-]*)*?"
    r"\s+-[A-Za-z]*c(?=\s)\s+(\"[^\"]*\"|'[^']*')"
)


def _iter_cd_targets(command: str, depth: int = 0):
    """Yield each command-position `cd` operand in `command` (issue #1188).

    A match with no operand (bare `cd`, or `cd --` with nothing following) is
    bash's `cd $HOME` and yields the sentinel `"~"`. A quoted operand is
    dequoted. An operand that is unresolvable without shell state — an
    unsubstituted `$VAR`/`` ` ``/glob metachar, or the literal `-` for `cd -`
    (needs OLDPWD, which this hook does not have) — is skipped: fail open,
    per the #917 doctrine, rather than guessed at.

    Issue #1190: the scan runs over the quote-MASKED copy (falling back to the
    raw command when a quote is unterminated — fail closed), but each operand
    is sliced from the ORIGINAL string via the match span, so the dequote and
    the fail-open checks below see real text rather than mask filler.

    Issue #1192: the quote mask runs on top of the heredoc-body mask, not the
    raw command — heredoc-FIRST is what removes a stray body apostrophe
    (`don't stop`) that would otherwise force the quote scanner's
    unterminated-quote fail-CLOSED fallback. Both masks are length-preserving,
    so their composition remains a valid source of match spans into the
    ORIGINAL `command`.

    Issue #1192, depth-capped nested-shell scan: at `depth == 0`, after the
    ordinary `_CD_RE` pass, also run `_NESTED_SHELL_RE` over the SAME masked
    `scan` (never the raw `command` — running it over the raw command would
    reopen the #1190 over-block class, matching quoted PROSE that merely
    NAMES the `bash -c '...'` shape, e.g. inside a commit message). Each
    match's quoted argument is sliced from the ORIGINAL `command` (both masks
    preserve quote delimiters and length, so the span is a valid slice),
    dequoted, and — for the double-quoted form only — unescaped (`\\"` → `"`,
    `\\\\` → `\\`). The inner string then recurses through this SAME function
    at `depth=1`, so it inherits quote masking, heredoc masking, the `cd -`
    skip and the `$`/backtick/glob fail-open for free, rather than needing a
    bespoke inner scanner. `depth >= 1` returns immediately without a nested
    scan of its own — a hard cap, so `bash -c "bash -c '...'"` is a
    documented gap, not unbounded recursion (#1188 ruled out full shell
    emulation).
    """
    hd = _mask_heredoc_bodies(command)
    masked = _mask_quoted_regions(hd)
    scan = hd if masked is None else masked
    for m in _CD_RE.finditer(scan):
        if m.group(2) is None:
            yield "~"
            continue
        start, end = m.span(2)
        operand = command[start:end]
        if len(operand) >= 2 and operand[0] == operand[-1] and operand[0] in "\"'":
            operand = operand[1:-1]
        if operand == "-":
            continue
        if any(ch in operand for ch in "$`*?["):
            continue
        yield operand

    if depth:
        return
    for m in _NESTED_SHELL_RE.finditer(scan):
        start, end = m.span(1)
        arg = command[start:end]
        quote_char = arg[0]
        inner = arg[1:-1]
        if quote_char == '"':
            inner = inner.replace('\\"', '"').replace("\\\\", "\\")
        yield from _iter_cd_targets(inner, depth=1)


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
        # Var-as-path-prefix scrub (Issue #1153, fingerprint 3): when an
        # uppercase $VAR/${VAR} is IMMEDIATELY followed by `/`, replace the
        # var reference with a NON-delimiter sentinel (NUL — not in the
        # token-boundary class below, and not `/`) BEFORE the scrub-to-empty
        # passes. This makes the trailing `/frag` land MID-WORD (preceded by
        # the sentinel, not a real delimiter), so the token-boundary-anchored
        # capture below never surfaces it as a candidate absolute path — e.g.
        # `"$VENV/Scripts/python.exe"` no longer yields the spurious
        # `/Scripts/python.exe` candidate, and `"$X/../../.."` no longer
        # yields `/../../..`. A standalone $VAR NOT followed by `/` (no
        # lookahead match here) falls through to the scrub-to-empty passes
        # below unchanged, preserving the #353 behavior for cases like
        # `${CLAUDE_PLUGIN_ROOT}/hooks/...` and `$HOME/anything` (same
        # end-result ALLOW, now via never-capturing rather than
        # capture-then-drop).
        scrubbed = re.sub(r"\$\{[A-Z_][A-Z0-9_]*\}(?=/)", "\x00", command)
        scrubbed = re.sub(r"\$[A-Z_][A-Z0-9_]*(?=/)", "\x00", scrubbed)
        scrubbed = re.sub(r"\$\{[A-Z_][A-Z0-9_]*\}", "", scrubbed)
        scrubbed = re.sub(r"\$[A-Z_][A-Z0-9_]*", "", scrubbed)
        # Anchor the leading `/` at a real TOKEN BOUNDARY (start-of-string or a
        # preceding whitespace / shell-delimiter / quote) so a `/`-substring in
        # the MIDDLE of a token is NOT captured. Without this, an in-repo
        # RELATIVE path like `.venv-host/Scripts/python.exe` yields the mid-word
        # capture `/Scripts/python.exe`, which — on a host where that substring
        # exists OUTSIDE the project — is wrongly flagged
        # `BLOCKED: path outside project boundary`. `.venv-host/` is the
        # documented gitignored host venv at the repo root (inside the project).
        # A genuine out-of-repo absolute path begins at a delimiter (e.g.
        # `cat /etc/passwd`, leading `//etc/passwd`) and so still matches and
        # still blocks. (Issue #1135.)
        # Exclude backslash from the captured token class (Issue #1153,
        # fingerprint 3): a Windows backslash token (e.g. `..\\..\\python.exe`)
        # has no `/`-leading form to begin with, but excluding `\` from the
        # class also keeps a backslash-containing token from spanning past a
        # separator and manufacturing a `/`-anchored sub-fragment. No in-repo
        # POSIX path literal contains a backslash, so this is Linux-safe.
        for m in re.finditer(
            r'(?:^|(?<=[\s"\'`;<>|&=(]))(/[^\s"\';<>|&\\]+)', scrubbed
        ):
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
            # Skip a pure relative-traversal fragment (only `.`/`..` segments,
            # e.g. `/../../..`) — never a real absolute path, just the
            # collapsed residue of a `$VAR/../../..`-shaped fragment after the
            # var scrub. Belt-and-suspenders alongside the var-as-path-prefix
            # sentinel scrub above. (Issue #1153, fingerprint 3.)
            if re.match(r"^/(?:\.\.?/)*\.\.?$", candidate):
                continue
            # Windows/MSYS-shaped tokens (e.g. an MSYS `/c/...` repo-root
            # reference) never exist on the POSIX CI host, so the exists()
            # check below would always drop them before the boundary check
            # ever runs — masking the real over-/under-block. Let them
            # through to `is_allowed`/`_canon` instead. Non-Windows fragments
            # (branch names, commit-message fragments, #1135 mid-word
            # residue) are still dropped here exactly as before. (Issue
            # #1153, fingerprint 2.)
            if not _looks_windows(candidate) and not os.path.exists(candidate):
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

# cd-escape gate (issue #1188). Placed LAST in the Bash flow, strictly
# ADDITIVE to everything above: it can only ADD blocks, and every existing
# `BLOCKED: path outside project boundary: …` message above stays
# byte-for-byte unchanged, so no pre-existing stderr grep shifts. Wrapped in
# try/except so a guard hook that cannot parse/resolve its input never wedges
# the session (#917 fail-open doctrine) — any unexpected error here falls
# through to ALLOW, same as the rest of this best-effort hook.
if tool_name == "Bash":
    try:
        command = tool_input.get("command", "")
        for target in _iter_cd_targets(command):
            t = os.path.expanduser(target)
            if _looks_windows(t):
                resolved = t
            else:
                if not os.path.isabs(t):
                    t = os.path.join(_cd_anchor(), t)
                resolved = os.path.realpath(t)
            # /tmp carve-out parity with extract_paths()'s existing skip —
            # tests/test-restrict-paths-worktree-git.sh documents this as an
            # invariant many mktemp-based flows depend on.
            if resolved.startswith("/tmp"):
                continue
            if not is_allowed(resolved):
                print(
                    f"BLOCKED: cd target outside project boundary: {target} "
                    f"(resolves to {resolved})",
                    file=sys.stderr,
                )
                sys.exit(2)
    except Exception:
        pass
