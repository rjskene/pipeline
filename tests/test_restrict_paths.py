"""Discoverable-via-wrapper unittest for hooks/restrict_paths.py (issue #1136).

Drives the real hook as a subprocess with a JSON stdin payload, asserting the
hook's exit code (2 = blocked, 0 = allowed) — mirrors the subprocess-isolation
convention of tests/test_block_deletions.py / tests/test-restrict-paths-hook.sh.

This is the SPLIT-ROLE RED suite. It pins the post-fix behavior for two
over-match bugs in the path guard while keeping the genuine guard intact:

  Bug 1 — a relative in-repo path (e.g. a `Scripts/` segment under a host venv)
          is wrongly BLOCKED because the boundary check resolves the relative
          path against the hook process CWD instead of the project root. Fix
          anchors relative resolution on PROJECT_DIR.
  Bug 2 — the protected-control-file guard over-fires on any command/argument
          that merely NAMES a protected control file (a read / find / ls /
          grep, or a copy SOURCE). Fix gates the guard on an actual WRITE
          position; reads/references are allowed, writes stay blocked.

Against the CURRENT unfixed hook the Bug-1 / Bug-2 ALLOW cases FAIL (the hook
over-blocks them with exit 2) — that is the point of a RED suite. The
still-BLOCK cases (out-of-boundary reads, `..`-escape, `//`-collapse, inline
disarm, and the copy/move/dd/truncate DESTINATION cases) pass now and MUST keep
passing post-fix.

Issue #1138 extends this RED suite with two further evasions that #1136's
write-position scan (keyed on the last non-flag positional) incidentally
re-opened — this is a RE-TIGHTENING (it only ADDS blocks; no PROTECTED pattern
is widened):

  Bug 1138.1 — dest-via-flag: a protected dir handed to the copy/move family via
               `-t <dir>` / `-t<dir>` / `--target-directory[=| ]<dir>` is the
               real write destination but lives in a FLAG (or its argument), so
               the last-positional check never sees it. Fix derives an explicit
               flag-dest for cp/mv/install/ln (NOT rsync — its `-t` is
               `--times`); when set it IS the dest and positionals are sources
               (so a protected cp-SOURCE with a safe `-t` dest stays ALLOWED).
  Bug 1138.2 — interpreter inline-script write: `python -c` / `node -e` /
               `perl -e` / `ruby -e` can write a protected file without naming it
               as a shell positional. Fix blocks an interpreter-inline
               invocation that NAMES a protected token, while a normal script run
               carrying an unrelated `-e`-looking arg stays ALLOWED.

Against the CURRENT hook the #1138 real-miss BLOCK cases SLIP (exit 0 where a
block/exit-2 is expected) and the cp-protected-SOURCE-with-`-t`-dest ALLOW guard
over-blocks (exit 2) — that is the RED state these tests pin. The #1138 pins
(dest-last `cp evil -t <dir>`, `mv evil -t <dir>`, and the `perl -e` redirect
form) already block today and MUST keep blocking post-fix.

Re-tighten (PR-evaluator gap): the NO-SPACE glued `-t<dir>` dest form (e.g.
`cp -t<protected> evil`) ALSO slips (exit 0) — flag-dest derivation matches the
glued target, but the final outer Bash block re-scans the FULL command with
PROTECTED_CMD_PATTERNS, whose leading-delimiter class is unsatisfied when the
protected token is glued to the `t` of `-t`, so the hook falls through. The
spaced `-t <dir>` (space delimiter) and `--target-directory=<dir>` (`=`
delimiter) forms already block and MUST keep blocking; the glued-form BLOCK
cases below are RED against the current hook.

Issue #1188 extends this suite again with the `cd`-escape class: the Bash
extractor scans the command string for `/`-anchored absolute tokens and has NO
model of the shell working directory, so `cd <anywhere> && <write to a plain
relative path>` leaves the project boundary with nothing to extract. The
post-fix hook resolves a COMMAND-POSITION leading `cd` operand against the
event-payload `cwd` (when that is itself in-boundary) or PROJECT_DIR, and blocks
the whole command when the target lands outside the boundary — reusing
`is_allowed` verbatim so the `/tmp` carve-out, `~/.claude`, sibling/nested
worktrees, and the Windows/MSYS `_canon` branch all come along for free.

Fixture anchoring is LOAD-BEARING for the #1188 cases: `cls.PROJECT` is a
`/tmp`-rooted mkdtemp, and `cd ..` from there lands on `/tmp`, which the
extractor exempts unconditionally — every relative-`cd` BLOCK assertion would
then pass/fail for the wrong reason. So the #1188 cases run against a separate
`$HOME`-anchored project fixture (`cls.P1188`), mirroring the MIDWORD_EXISTS
precedent in setUpClass.

Against the CURRENT hook every #1188 NEW-BLOCK case SLIPS (exit 0 where exit 2
is expected) — that is the RED state. The #1188 ALLOW / KEEP-BLOCK pins pass
today AND must keep passing post-fix; they exist so the GREEN implementation
cannot degrade into a blanket "any `cd` blocks".

Issue #1190 narrows that same #1188 scan. Its command-position lookbehind
(`;`, `&`, `|`, `(`, `{`) has NO notion of quoting, so a separator that appears
INSIDE a quoted string still opens a command position: any benign quoted text
that happens to carry a separator followed by a change-directory word and a
relative parent — a commit message, a `printf` payload, a variable assignment
holding prose — is parsed as a real command and BLOCKED. The post-fix hook
masks quoted regions (length-preserving, delimiters kept) before the scan and
slices operands from the ORIGINAL string.

Against the CURRENT hook every #1190 ALLOW case (`test_issue1190_allow_*`,
except the two explicitly labelled non-RED) FAILS with exit 2 and
`BLOCKED: cd target outside project boundary` — that, precisely, is the #1190
defect and the RED state. The `test_issue1190_block_*` cases pass TODAY and
must keep passing: they are the anti-under-block floor (a real `cd` beside a
decoy quoted region, a real `cd` after a balanced quoted region, a quoted
TARGET, unterminated quotes failing CLOSED, a backslash-escaped quote outside
quotes) plus the scope guard that masking must never reach `extract_paths()`.

Hermeticity note: the hook is driven against a freshly created temp project
directory (NOT this worktree's own path). A worktree's own directory is
"sibling-worktree shaped" relative to its parent, which would make the hook's
worktree-destination carve-out (`_command_has_worktree_dest`) falsely exempt the
absolute-destination BLOCK case. A non-worktree temp project dir keeps every
assertion deterministic whether the suite runs from inside this worktree, on the
base branch, or in CI.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HOOK = REPO_ROOT / "hooks" / "restrict_paths.py"

# Protected control-file paths built from fragments (the `DEVNULL = "/dev/" +
# "null"` convention in tests/test_block_deletions.py) so this test SOURCE never
# trips the live restrict_paths guard — or a future source scan — on its own
# protected-path literals.
DOT = ".claude/"
SET = DOT + "settings.json"            # a protected control file (relative)
SETL = DOT + "settings.local.json"     # a protected control file (relative)
HK = DOT + "hooks/"                     # the protected hooks dir (relative)
# Issue #1212 — gitignored scratch dir (NOT protected) and a plugin cache
# hooks dir shape (protected, 4th PROTECTED_CMD_PATTERNS entry).
SCRATCH = DOT + "scratch/"
CACHE_HOOKS = DOT + "plugins/cache/mkt/pipeline/1.0.0/hooks/"

# A relative in-repo path with a `Scripts/` segment (Bug 1 reproducer). Built
# from fragments to keep the literal from looking like anything special.
SCRIPTS_EXE = ".venv-host/Scri" + "pts/python.exe"
SCRIPTS_DIR = ".venv-host/Scri" + "pts/"

BLOCK = 2   # restrict_paths exits 2 when it blocks
ALLOW = 0

# ---------------------------------------------------------------------------
# Issue #1153 — Windows/MSYS host over-block simulations.
#
# The hook over-blocks legitimate work on Windows-host consumers via three
# fingerprints: (1) the Claude session scratchpad under Temp/claude/ is outside
# the boundary; (2) MSYS `/c/…` / backslash `C:\…` repo-root references are not
# normalized before the boundary compare; (3) the Bash token-extractor surfaces
# spurious absolute paths from var-prefixed / relative / backslash fragments.
#
# These simulations are HERMETIC on the POSIX CI host: Windows-shaped path
# strings drive the hook's pure-string canonicalization, never the filesystem.
# WIN_ROOT is a Windows-form project root; the subprocess cwd stays the real
# temp PROJECT (see _win_allow/_win_block) so subprocess.run can launch — the
# Windows root does not exist on disk here.
# ---------------------------------------------------------------------------
WIN_ROOT = "C:" + "\\Users\\u\\repo"          # a Windows-form project root
_WSLUG = "myproj"
_WSESS = "sess-abc"
# Session scratchpad under the harness-advertised Temp/claude/ session root, in
# both MSYS (`/c/…`) and backslash (`C:\…`) forms.
SCRATCH_MSYS = (
    "/c/Users/u/AppData/Local/Temp/claude/" + _WSLUG + "/" + _WSESS
    + "/scratchpad/note.txt"
)
SCRATCH_BSL = (
    "C:\\Users\\u\\AppData\\Local\\Temp\\claude\\" + _WSLUG + "\\" + _WSESS
    + "\\scratchpad\\note.txt"
)
# A Temp path that is NOT under the Temp/claude/ session root (must stay blocked).
NON_CLAUDE_TEMP_MSYS = "/c/Users/u/AppData/Local/Temp/other/x.txt"

# ---------------------------------------------------------------------------
# Issue #1188 — `cd`-escape literals, built from fragments (the
# `DEVNULL = "/dev/" + "null"` convention above) so this test SOURCE never
# carries a bare out-of-boundary absolute literal that a future source scan
# could trip on.
# ---------------------------------------------------------------------------
ETC = "/e" + "tc"                       # an out-of-boundary absolute cd target
WIN_VOL = "C:" + "\\volumes"            # backslash Windows drive-root target
MSYS_VOL = "/c" + "/volumes"            # MSYS drive-root target
# The stderr fingerprint the #1188 gate must emit — deliberately DISTINCT from
# the pre-existing `BLOCKED: path outside project boundary` string, which the
# additive-placement discipline leaves byte-for-byte unchanged.
CD_BLOCK_MSG = "BLOCKED: cd target outside project boundary"
# The pre-existing absolute-token extractor's fingerprint. Named here because
# the #1190 scope guard (K7) asserts that masking does NOT reach
# `extract_paths()` — a quoted absolute out-of-boundary token must still emit
# THIS message, not the cd-gate one.
PATH_BLOCK_MSG = "BLOCKED: path outside project boundary"

# ---------------------------------------------------------------------------
# Issue #1192 — nested shell strings, heredoc bodies, ANSI-C quoting.
# ---------------------------------------------------------------------------
# A SEVEN-deep `..` chain. Every #1192 cd case uses this rather than a literal
# `../..`: the `self.P1188` fixture sits a few levels under $HOME, so a shallow
# chain can normalize back to a path the boundary check still accepts and the
# assertion then passes for the wrong reason. Seven levels collapse to `/` from
# any realistic fixture depth (same reasoning as the 7-deep chains in
# tests/test-restrict-paths-hook.sh Block 7/8).
UP7 = "/".join([".."] * 7)
# `/dev/null` as a fragment (the `DEVNULL = "/dev/" + "null"` convention) — used
# by the two-heredocs-on-one-line case as a second redirect target.
DEVNULL = "/dev/" + "null"
# The protected-write guard's fingerprint. Named here because #1192's heredoc
# mask must leave a REAL redirect into a protected control file blocked with
# THIS message, while it must stop firing for a protected-looking token that
# merely lives inside a heredoc BODY.
PROT_BLOCK_MSG = "cannot modify protected file"


class TestRestrictPaths(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # A NON-worktree-shaped project root (basename is not `wt-N-...`) and a
        # separate dir that is OUTSIDE the project (used as the hook CWD for the
        # Bug-1 relative-resolution cases).
        cls._proj_tmp = tempfile.mkdtemp(prefix="rp-proj-")
        cls._out_tmp = tempfile.mkdtemp(prefix="rp-outside-")
        cls.PROJECT = os.path.realpath(cls._proj_tmp)
        cls.OUTSIDE = os.path.realpath(cls._out_tmp)
        # issue #1135: a real EXISTING out-of-project dir whose
        # `<dir>/Scripts/python.exe` exists on disk. Used to make the mid-word
        # `/`-capture bug deterministic: glued as a suffix to a prefix word, the
        # substring the extractor captures from the first `/` resolves to this
        # existing out-of-project path. The extractor must NOT capture it from
        # mid-word (token-boundary anchor); a true leading-delimiter reference to
        # it must still BLOCK. Created under /tmp is fine — these are NOT passed
        # as the candidate directly (the /tmp skip only short-circuits tokens
        # that BEGIN with /tmp; a mid-word glued capture begins with the realpath
        # of this dir, which is under /tmp but the captured substring is the
        # whole `<realpath>/Scripts/python.exe`, still /tmp-prefixed). To avoid
        # the extractor's `/tmp` skip masking the assertion, anchor it OUTSIDE
        # /tmp under the home dir.
        cls._midword_tmp = tempfile.mkdtemp(
            prefix=".rp-midword-", dir=os.path.expanduser("~")
        )
        cls.MIDWORD_EXISTS = os.path.realpath(cls._midword_tmp)
        os.makedirs(os.path.join(cls.MIDWORD_EXISTS, "Scripts"), exist_ok=True)
        with open(
            os.path.join(cls.MIDWORD_EXISTS, "Scripts", "python.exe"), "w",
            encoding="utf-8",
        ) as fh:
            fh.write("")

        # issue #1188 — a SEPARATE project fixture anchored under $HOME, NOT
        # /tmp. MANDATORY: `cls.PROJECT` above is `/tmp/rp-proj-*`, so `cd ..`
        # from it lands on /tmp, which the extractor exempts unconditionally
        # (restrict_paths.py `candidate.startswith("/tmp")`). Every relative-`cd`
        # escape assertion would then pass/fail for the wrong reason. Same
        # reasoning as the MIDWORD_EXISTS $HOME anchor directly above.
        #
        # Layout:
        #   <home-tmp>/proj                       -> cls.P1188 (the project root)
        #   <home-tmp>/proj/sub/deep              -> in-project cd targets
        #   <home-tmp>/proj/.claude/worktrees/wt-42-x -> NESTED_WORKTREE_PATTERN
        #   <home-tmp>/wt-42-x                    -> SIBLING worktree
        #                                            (WORKTREE_PATTERN)
        # The sibling is built from os.path.dirname(cls.P1188) — NOT the
        # non-realpath'd mkdtemp result — because WORKTREE_PATTERN is anchored on
        # os.path.dirname(PROJECT_DIR) where PROJECT_DIR is realpath'd. On a host
        # whose $HOME traverses a symlink the two diverge and the sibling pin
        # would fail for the wrong reason.
        cls._h1188 = tempfile.mkdtemp(prefix=".rp-1188-", dir=os.path.expanduser("~"))
        cls.P1188 = os.path.realpath(os.path.join(cls._h1188, "proj"))
        os.makedirs(os.path.join(cls.P1188, "sub", "deep"), exist_ok=True)
        os.makedirs(
            os.path.join(cls.P1188, ".claude", "worktrees", "wt-42-x"), exist_ok=True
        )
        os.makedirs(
            os.path.join(os.path.dirname(cls.P1188), "wt-42-x"), exist_ok=True
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._proj_tmp, ignore_errors=True)
        shutil.rmtree(cls._out_tmp, ignore_errors=True)
        shutil.rmtree(cls._midword_tmp, ignore_errors=True)
        shutil.rmtree(cls._h1188, ignore_errors=True)

    # --- subprocess driver -------------------------------------------------
    def run_hook(self, tool_name, tool_input, *, cwd=None, project_dir=None,
                 payload_cwd=None):
        """Invoke the real hook; return (exit code, stderr).

        The hook resolves the project boundary from CLAUDE_PROJECT_DIR and
        resolves relative paths against the process CWD (the bug). We control
        both so the Bug-1 cases can put CWD outside the project.

        `payload_cwd` (issue #1188) adds the harness-supplied `cwd` key to the
        EVENT payload — distinct from the subprocess cwd. The current hook reads
        only `tool_name` / `tool_input` and never consults it; the #1188 `cd`
        gate anchors relative `cd` operands on it (when it is itself
        in-boundary), so the key must be omitted entirely when None to keep the
        pre-#1188 payload shape byte-for-byte for every other case.
        """
        proj = project_dir or self.PROJECT
        env = dict(os.environ)
        env["CLAUDE_PROJECT_DIR"] = proj
        event = {"tool_name": tool_name, "tool_input": tool_input}
        if payload_cwd is not None:
            event["cwd"] = payload_cwd
        payload = json.dumps(event)
        proc = subprocess.run(
            [sys.executable, str(HOOK)],
            input=payload, capture_output=True, text=True, env=env,
            cwd=cwd or proj,
        )
        return proc.returncode, proc.stderr

    def assertAllowed(self, tool_name, tool_input, *, cwd=None, project_dir=None,
                      payload_cwd=None):
        rc, err = self.run_hook(
            tool_name, tool_input, cwd=cwd, project_dir=project_dir,
            payload_cwd=payload_cwd,
        )
        self.assertEqual(
            rc, ALLOW,
            f"expected ALLOW (exit 0) for {tool_name} {tool_input!r}; got {rc}; stderr={err!r}",
        )

    def assertBlocked(self, tool_name, tool_input, *, cwd=None, project_dir=None,
                      payload_cwd=None):
        rc, err = self.run_hook(
            tool_name, tool_input, cwd=cwd, project_dir=project_dir,
            payload_cwd=payload_cwd,
        )
        self.assertEqual(
            rc, BLOCK,
            f"expected BLOCK (exit 2) for {tool_name} {tool_input!r}; got {rc}; stderr={err!r}",
        )

    def assertBlockedWith(self, substr, tool_name, tool_input, *, cwd=None,
                          project_dir=None, payload_cwd=None):
        """BLOCK (exit 2) AND stderr naming `substr` (issue #1188).

        Pins the operator-facing message, not just the exit code: the point of
        the #1188 gate is that the block names the RESOLVED destination, so the
        agent can tell a cd-escape block apart from the pre-existing
        `BLOCKED: path outside project boundary` string.
        """
        rc, err = self.run_hook(
            tool_name, tool_input, cwd=cwd, project_dir=project_dir,
            payload_cwd=payload_cwd,
        )
        self.assertEqual(
            rc, BLOCK,
            f"expected BLOCK (exit 2) for {tool_name} {tool_input!r}; got {rc}; stderr={err!r}",
        )
        self.assertIn(
            substr, err,
            f"expected stderr for {tool_input!r} to contain {substr!r}; got {err!r}",
        )

    # ======================================================================
    # Bug 1 — relative in-repo paths resolve against the PROJECT ROOT
    # ======================================================================
    # ALLOW (currently RED — over-blocked because the boundary check resolves
    # the relative path against the hook CWD, which we deliberately put OUTSIDE
    # the project). Post-fix these resolve against PROJECT_DIR → in-project →
    # ALLOWED.
    def test_bug1_allow_relative_scripts_path_read(self):
        self.assertAllowed("Read", {"file_path": SCRIPTS_EXE}, cwd=self.OUTSIDE)

    def test_bug1_allow_relative_scripts_dir_glob(self):
        self.assertAllowed("Glob", {"path": SCRIPTS_DIR}, cwd=self.OUTSIDE)

    # Contract / regression (passes pre- and post-fix): a relative Scripts/
    # executable invoked via Bash is never spuriously carve-blocked — relative
    # tokens are not boundary-extracted.
    def test_bug1_allow_bash_relative_scripts_invocation(self):
        self.assertAllowed("Bash", {"command": SCRIPTS_EXE + " -m pytest"}, cwd=self.OUTSIDE)

    # still-BLOCK — out-of-boundary / `..`-escape / `//`-collapse stay blocked
    # (#353 family). These pass now AND post-fix.
    def test_bug1_block_absolute_out_of_boundary_read(self):
        self.assertBlocked("Read", {"file_path": "/etc/passwd"})

    def test_bug1_block_relative_dotdot_escape_read(self):
        self.assertBlocked("Read", {"file_path": "../../../../etc/passwd"})

    def test_bug1_block_bash_cat_out_of_boundary(self):
        self.assertBlocked("Bash", {"command": "cat /etc/passwd"})

    def test_bug1_block_bash_double_slash_out_of_boundary(self):
        # `//etc/passwd` — POSIX collapses `//` to `/`; the boundary check
        # (os.path.realpath) catches it. (#353)
        self.assertBlocked("Bash", {"command": "cat //etc/passwd"})

    # ======================================================================
    # Bug 2 — protected-control-file guard gates on actual WRITE position
    # ======================================================================
    # ALLOW (currently RED — over-blocked because the guard fires on any
    # substring reference). Post-fix reads/references/copy-SOURCE are allowed.
    def test_bug2_allow_grep_protected(self):
        self.assertAllowed("Bash", {"command": "grep foo " + SET})

    def test_bug2_allow_cat_protected(self):
        self.assertAllowed("Bash", {"command": "cat " + SET})

    def test_bug2_allow_ls_protected_hooks_dir(self):
        self.assertAllowed("Bash", {"command": "ls " + HK})

    def test_bug2_allow_cp_protected_as_source(self):
        # The protected file is the read SOURCE, not the destination → allowed.
        self.assertAllowed("Bash", {"command": "cp " + SET + " backup.json"})

    def test_bug2_allow_read_tool_of_protected(self):
        self.assertAllowed("Read", {"file_path": SET})

    # Regression-keep (passes pre- and post-fix): naming a BARE settings.json
    # (no `.claude/` prefix) is not a protected reference at all.
    def test_bug2_allow_find_bare_settings_name(self):
        self.assertAllowed("Bash", {"command": "find . -name set" + "tings.json"})

    # still-BLOCK — inline disarm via in-place / redirect / structured writes
    # stays blocked (#964). These pass now AND post-fix.
    def test_bug2_block_sed_inplace_protected(self):
        self.assertBlocked("Bash", {"command": "sed -i s/a/b/ " + SET})

    def test_bug2_block_redirect_into_protected(self):
        self.assertBlocked("Bash", {"command": "echo x > " + SET})

    def test_bug2_block_tee_protected(self):
        self.assertBlocked("Bash", {"command": "tee " + SET})

    def test_bug2_block_printf_redirect_protected(self):
        self.assertBlocked("Bash", {"command": "printf x > " + SET})

    def test_bug2_block_redirect_disarm_hook_file(self):
        self.assertBlocked("Bash", {"command": 'echo "" > ' + HK + "restrict_paths.py"})

    def test_bug2_block_absolute_in_project_write(self):
        cmd = "printf x > " + self.PROJECT + "/" + SET
        self.assertBlocked("Bash", {"command": cmd})

    def test_bug2_block_write_tool_protected(self):
        self.assertBlocked("Write", {"file_path": SET})

    def test_bug2_block_edit_tool_protected(self):
        self.assertBlocked("Edit", {"file_path": SET})

    # still-BLOCK — copy/move/dd/truncate DESTINATION (the source-vs-dest
    # loosening branch the evaluator flagged). Relative AND absolute dest token
    # shapes are pinned so a minimum-code predicate that detects only absolute
    # positional dests fails the relative cases. These pass now AND post-fix.
    def test_bug2_block_cp_relative_protected_dest(self):
        self.assertBlocked("Bash", {"command": "cp evil.json " + SET})

    def test_bug2_block_mv_relative_protected_dest(self):
        self.assertBlocked("Bash", {"command": "mv evil.json " + SET})

    def test_bug2_block_cp_absolute_protected_dest(self):
        cmd = "cp evil.json " + self.PROJECT + "/" + SET
        self.assertBlocked("Bash", {"command": cmd})

    def test_bug2_block_dd_of_protected(self):
        self.assertBlocked("Bash", {"command": "dd of=" + SET})

    def test_bug2_block_truncate_protected(self):
        self.assertBlocked("Bash", {"command": "truncate -s0 " + SET})

    # ======================================================================
    # Bug 1138.1 — dest-via-flag bypass (cp/mv/install/ln -t/--target-directory)
    # ======================================================================
    # NEW BLOCK — the protected dir is the real write DESTINATION but lives in a
    # `-t`/`--target-directory` flag, so #1136's last-non-flag-positional scan
    # never sees it. The first/eq/install cases SLIP (exit 0) against the CURRENT
    # hook — that is the RED miss this re-tightening closes. rsync is deliberately
    # NOT in this family (its `-t` is `--times`, not a target dir).
    def test_bug1138_block_cp_dest_via_t_flag_first(self):
        # dest in the -t flag, SOURCE last → currently ALLOWED (the real miss).
        self.assertBlocked("Bash", {"command": "cp -t " + HK + " evil.py"})

    def test_bug1138_block_install_dest_via_t_flag(self):
        # currently ALLOWED (the real miss).
        self.assertBlocked("Bash", {"command": "install -t " + HK + " evil"})

    def test_bug1138_block_cp_target_directory_eq(self):
        # --target-directory=<dir>: the whole flag token is dropped → ALLOWED.
        self.assertBlocked("Bash", {"command": "cp --target-directory=" + HK + " evil"})

    def test_bug1138_block_cp_dest_via_t_flag_last(self):
        # dest-last ordering blocks today by coincidence (flag-arg lands last) —
        # pin it so the explicit flag-dest derivation keeps it blocked.
        self.assertBlocked("Bash", {"command": "cp evil -t " + HK})

    def test_bug1138_block_mv_dest_via_t_flag(self):
        # pin (dest-last coincidence today).
        self.assertBlocked("Bash", {"command": "mv evil -t " + HK})

    # NEW ALLOW — the flag-dest fix must not over-block a non-protected `-t`
    # target, and a protected file used as the cp SOURCE (with a safe `-t` dest)
    # stays ALLOWED. The protected-SOURCE guard is currently RED: pre-fix branch 5
    # keys the dest on the last positional (= the protected SOURCE) → over-blocks.
    def test_bug1138_allow_cp_t_nonprotected_dir(self):
        self.assertAllowed("Bash", {"command": "cp -t backupdir/ evil.json"})

    def test_bug1138_allow_cp_target_directory_nonprotected(self):
        self.assertAllowed("Bash", {"command": "cp --target-directory=backupdir/ evil.json"})

    def test_bug1138_allow_cp_protected_source_t_dest(self):
        # protected file is the read SOURCE; the -t dest is non-protected → ALLOW
        # (currently RED — pre-fix keys the dest on the last positional = SET).
        self.assertAllowed("Bash", {"command": "cp -t backupdir/ " + SET})

    # --- glued NO-SPACE dest-via-flag (`-t<protected>`) — #1138 re-tighten ----
    # NEW BLOCK — the NO-SPACE concatenated `-t<protected-dir>` form is the real
    # disarm vector the PR evaluator found. The hook's flag-dest derivation DOES
    # set flag_dest=<protected> for this shape (the glued `-t<dir>` branch), so
    # `_protected_write_context` returns True — but the FINAL outer Bash block
    # then re-scans the FULL command with PROTECTED_CMD_PATTERNS, whose leading
    # delimiter class `(?:^|[\s=>'"|&;(])` is NOT satisfied: in `cp -t.claude/…`
    # the protected token is preceded by the `t` of `-t` (not a delimiter, not
    # start-of-string), so no full-command pattern matches and the hook FALLS
    # THROUGH to exit 0. The glued form therefore SLIPS today (exit 0) — RED.
    # The spaced `-t <dir>` form has a space delimiter and already blocks (pinned
    # above); the `--target-directory=<dir>` form has an `=` delimiter and also
    # already blocks. Do NOT touch those — these ADD the glued-form blocks.
    def test_bug1138_block_cp_glued_t_hooks_dir(self):
        # `cp -t<hooks> evil.py` — currently ALLOWED (the real miss).
        self.assertBlocked("Bash", {"command": "cp -t" + HK + " evil.py"})

    def test_bug1138_block_install_glued_t_hooks_dir(self):
        # `install -t<hooks> evil` — currently ALLOWED (the real miss).
        self.assertBlocked("Bash", {"command": "install -t" + HK + " evil"})

    def test_bug1138_block_ln_glued_t_hooks_dir(self):
        # `ln -t<hooks> evil` — currently ALLOWED (the real miss).
        self.assertBlocked("Bash", {"command": "ln -t" + HK + " evil"})

    def test_bug1138_block_cp_glued_t_settings_file(self):
        # `cp -t<settings.json> evil` — currently ALLOWED (the real miss).
        self.assertBlocked("Bash", {"command": "cp -t" + SET + " evil"})

    # NEW ALLOW (anchoring) — a benign glued `-t<dir>` whose target is NOT a
    # protected dir stays ALLOWED, so the eventual fix can't degrade into a
    # blanket "glued -t blocks everything". `.backupdir/` is not protected; the
    # leading dot mirrors the protected shape to lock the anchoring precisely.
    def test_bug1138_allow_cp_glued_t_nonprotected_dir(self):
        self.assertAllowed("Bash", {"command": "cp -t.backupdir/ evil.json"})

    # ======================================================================
    # Bug 1138.2 — interpreter inline-script write (python -c / node -e / …)
    # ======================================================================
    # NEW BLOCK — an interpreter inline script (-c/-e/--eval) can write a
    # protected control file without ever naming it as a shell positional, so the
    # command-string scan is blind to it. The python/node cases SLIP (exit 0)
    # against the CURRENT hook — the real miss. Post-fix the
    # (interpreter-inline ∧ protected-token) signal BLOCKS.
    def test_bug1138_block_python_c_write_protected(self):
        # currently ALLOWED (the real miss).
        cmd = "python -c " + 'open("' + SET + '","w").write("x")'
        self.assertBlocked("Bash", {"command": cmd})

    def test_bug1138_block_node_e_write_protected(self):
        # currently ALLOWED (the real miss).
        cmd = "node -e " + 'fs.writeFileSync("' + SET + '","x")'
        self.assertBlocked("Bash", {"command": cmd})

    def test_bug1138_block_perl_e_write_protected(self):
        # blocks today via the redirect-`>` branch; pin so branch-6's
        # interpreter-inline signal keeps it blocked.
        cmd = "perl -e " + 'open(F,">' + SET + '")'
        self.assertBlocked("Bash", {"command": cmd})

    def test_bug1138_block_python3_c_hooks_dir(self):
        # covers `python3` + the hooks dir; currently ALLOWED (the real miss).
        cmd = "python3 -c " + 'open("' + HK + 'x","w")'
        self.assertBlocked("Bash", {"command": cmd})

    # NEW ALLOW — branch 6 fires ONLY on a NAMED protected token, and the
    # inline-flag match is anchored to the interpreter word so a normal script
    # run carrying an unrelated `-e` arg is NOT treated as an inline eval.
    def test_bug1138_allow_python_c_no_protected_token(self):
        self.assertAllowed("Bash", {"command": "python -c " + "print(1)"})

    def test_bug1138_allow_python_c_nonprotected_path(self):
        self.assertAllowed("Bash", {"command": "python -c " + 'open("notes.txt","w")'})

    def test_bug1138_allow_python_script_with_e_arg(self):
        # a real script invocation carrying an unrelated -e arg, NOT an inline
        # eval → ALLOW (locks the inline-regex anchoring).
        self.assertAllowed("Bash", {"command": "python script.py -e foo"})

    # ======================================================================
    # Issue #1212 — `_protected_write_context` branch 1 (redirect-target scan)
    # matches ANY path containing `.claude/`, not just the protected control
    # files in PROTECTED_PATTERNS. A redirect into the gitignored, inert
    # `.claude/scratch/` dir (the agent commit-message scratchpad idiom) is
    # therefore over-blocked. Fix: isolate the redirect TARGET token and match
    # it against PROTECTED_PATTERNS instead of the bare `.claude/` prefix.
    # Against the CURRENT (unfixed) hook the 5 scratch cases below are RED
    # (exit 2 where 0 is expected); the still-BLOCK cases pass now AND
    # post-fix; the quoted-settings case is RED in the other direction (exit
    # 0 where 2 is expected — the bonus fix for the pre-existing quoted-target
    # bypass).
    # ======================================================================

    # --- newly-ALLOWED: redirect into the gitignored scratch dir -----------
    def test_1212_allow_heredoc_scratch_cmsg(self):
        # The "write a multi-line commit message, then commit with it" idiom.
        cmd = (
            "cat > " + SCRATCH + "cmsg.txt <<'EOF' && git commit -F " + SCRATCH + "cmsg.txt\n"
            "fix: something\n"
            "EOF"
        )
        self.assertAllowed("Bash", {"command": cmd})

    def test_1212_allow_printf_scratch(self):
        # Exact reproduction from the issue.
        self.assertAllowed("Bash", {"command": "printf x > " + SCRATCH + "cmsg.txt"})

    def test_1212_allow_combo_scratch_and_add(self):
        self.assertAllowed(
            "Bash", {"command": "printf 'x' > " + SCRATCH + "c.txt && git add foo.py"}
        )

    def test_1212_allow_scratch_append(self):
        self.assertAllowed("Bash", {"command": "printf 'x' >> " + SCRATCH + "log.txt"})

    def test_1212_allow_scratch_abs(self):
        # Absolute path into the scratch dir (e.g. a worktree-anchored path).
        cmd = "printf x > " + self.PROJECT + "/" + SCRATCH + "x.txt"
        self.assertAllowed("Bash", {"command": cmd})

    # --- still-BLOCK: genuine disarm shapes stay blocked --------------------
    def test_1212_block_settings_redirect(self):
        self.assertBlocked("Bash", {"command": "echo x > " + SET})

    def test_1212_block_settings_local_redirect(self):
        self.assertBlocked("Bash", {"command": "echo x > " + SETL})

    def test_1212_block_settings_append(self):
        self.assertBlocked("Bash", {"command": "echo x >> " + SET})

    def test_1212_block_hooks_redirect(self):
        self.assertBlocked("Bash", {"command": "echo x > " + HK + "foo.py"})

    def test_1212_block_abs_hooks_redirect(self):
        cmd = "echo x > " + self.PROJECT + "/" + HK + "foo.py"
        self.assertBlocked("Bash", {"command": cmd})

    def test_1212_block_fd_prefixed_redirect(self):
        self.assertBlocked("Bash", {"command": "echo x 2> " + SET})

    def test_1212_block_clobber_redirect(self):
        self.assertBlocked("Bash", {"command": "echo x >| " + SET})

    def test_1212_block_truncate_colon_redirect(self):
        self.assertBlocked("Bash", {"command": ": > " + SET})

    def test_1212_block_hooks_sed_inplace(self):
        # Not branch 1 — pinned to confirm the fix doesn't disturb branch 2.
        self.assertBlocked("Bash", {"command": "sed -i s/a/b/ " + HK + "foo.py"})

    def test_1212_block_cp_onto_hooks(self):
        # Not branch 1 — pinned to confirm the fix doesn't disturb branch 5.
        self.assertBlocked("Bash", {"command": "cp evil.py " + HK + "foo.py"})

    def test_1212_block_plugins_cache_hooks_redirect(self):
        self.assertBlocked("Bash", {"command": "echo x > " + CACHE_HOOKS + "x.py"})

    # --- newly-BLOCKED (bonus fix): quoted redirect target ------------------
    def test_1212_block_quoted_settings_redirect(self):
        # Pre-fix, the leading quote stops the bare `.claude/` prefix match
        # dead — this ALLOWS today. Post-fix the optional `['"]?` closes the
        # hole.
        self.assertBlocked("Bash", {"command": 'echo x > "' + SET + '"'})

    # ======================================================================
    # Issue #1135 — Bash extractor must not capture a `/`-substring from the
    # MIDDLE of a relative in-repo path token.
    # ======================================================================
    # The Bash-branch path extractor regex `(/[^\s"';<>|&]+)` matches a `/`
    # ANYWHERE in the command text, so for an in-repo RELATIVE token like
    # `.venv-host/Scripts/python.exe` it captures the mid-word substring
    # `/Scripts/python.exe`. That captured substring is then `os.path.exists`-
    # checked and boundary-checked — on a host where a `/Scripts/...` (or any
    # captured `/abs/...` substring) exists OUTSIDE the project, the hook emits
    # `BLOCKED: path outside project boundary` for the in-repo `.venv-host`
    # interpreter. `.venv-host/` is the documented gitignored host venv AT the
    # repo root — inside the project. The fix anchors the extractor `/`-capture
    # at a real token boundary (start-of-string, whitespace, or a shell
    # delimiter/quote) so a relative token surfaces NO absolute candidate.
    def test_issue1135_allow_bash_venv_host_scripts_python_exe(self):
        # `.venv-host/Scripts/python.exe -m pytest` — the documented in-repo
        # host-venv interpreter. The relative token must NOT yield a captured
        # mid-word `/Scripts/...` candidate. ALLOWED.
        self.assertAllowed("Bash", {"command": SCRIPTS_EXE + " -m pytest"})

    def test_issue1135_allow_bash_ls_venv_host_scripts_dir(self):
        # `ls .venv-host/Scripts/` — even a plain listing of the dir. ALLOWED.
        self.assertAllowed("Bash", {"command": "ls " + SCRIPTS_DIR})

    # The deterministic mid-word-capture pin: glue the relative `.venv-host`
    # token to a prefix word such that the substring captured from the FIRST `/`
    # points at a real EXISTING absolute path OUTSIDE the project. Against the
    # CURRENT hook this captured substring is `os.path.exists`-true and
    # out-of-boundary → BLOCK (exit 2), which is the RED state. Post-fix the
    # token-boundary anchor refuses to capture mid-word, so no candidate is
    # surfaced → ALLOWED. (The out-of-project existing dir is created in
    # setUpClass as cls.MIDWORD_EXISTS so the assertion is hermetic.)
    def test_issue1135_allow_midword_slash_not_captured_from_relative_token(self):
        cmd = "venvprefix" + self.MIDWORD_EXISTS + "/Scripts/python.exe -m pytest"
        self.assertAllowed("Bash", {"command": cmd})

    # still-BLOCK — a genuine out-of-repo ABSOLUTE path (token-boundary leading
    # `/`) and a `..`-escape stay blocked. These pass now AND post-fix; pinned
    # so the fix cannot widen the genuine guard.
    def test_issue1135_block_bash_absolute_out_of_repo(self):
        # A real token-boundary absolute path to a known existing out-of-repo
        # file → BLOCK.
        self.assertBlocked("Bash", {"command": "cat /etc/passwd"})

    def test_issue1135_block_bash_absolute_out_of_repo_scripts_python(self):
        # The captured token starts at a true delimiter (leading space) and
        # resolves OUTSIDE the project → BLOCK. Uses the real existing
        # out-of-project dir created in setUpClass.
        cmd = "cat " + self.MIDWORD_EXISTS + "/Scripts/python.exe"
        self.assertBlocked("Bash", {"command": cmd})

    def test_issue1135_block_bash_dotdot_escape_outside_repo(self):
        # A `..`-escape that resolves OUTSIDE the repo via the Read tool stays
        # blocked (the genuine guard is untouched).
        self.assertBlocked("Read", {"file_path": "../../../../etc/passwd"})

    # ======================================================================
    # Issue #1153 — Windows/MSYS host over-block (three fingerprints)
    # ======================================================================
    # Windows-shaped paths must canonicalize (MSYS `/c/…` ↔ backslash `C:\…`)
    # before the boundary compare, the Claude session scratchpad must be
    # allowlisted, and the Bash token-extractor must stop manufacturing spurious
    # absolute paths from var-prefixed / relative / backslash fragments — WITHOUT
    # relaxing any genuine block. Each new case carries its empirically-verified
    # CURRENT-hook exit code so a "RED" case that already passes today is caught
    # as a planning defect (the earlier Revise failure).
    #
    # project_dir is a Windows-form root; cwd stays the real temp PROJECT so
    # subprocess.run can launch (the Windows root does not exist on the POSIX
    # host). The subprocess-cwd value is otherwise irrelevant — the fix keys the
    # project canonical key off the RAW CLAUDE_PROJECT_DIR, not realpath (which
    # mangles a Windows-shaped root on POSIX).
    def _win_allow(self, tool_name, tool_input):
        self.assertAllowed(tool_name, tool_input, project_dir=WIN_ROOT, cwd=self.PROJECT)

    def _win_block(self, tool_name, tool_input):
        self.assertBlocked(tool_name, tool_input, project_dir=WIN_ROOT, cwd=self.PROJECT)

    # --- Fingerprint 2: MSYS/Windows canonicalization + boundary reconcile --
    # RED today (exit 2): an MSYS `/c/…` reference to the repo root is a raw
    # string mismatch vs the realpath'd project dir → over-blocked. Post-fix the
    # canonical key (`c:/users/u/repo`) matches the project root → ALLOWED.
    def test_win_allow_msys_repo_root_read(self):
        self._win_allow("Read", {"file_path": "/c/Users/u/repo/sub/x.txt"})

    # RED today (exit 0 → NEW BLOCK): the Bash-branch exists-guard drops the
    # non-existent `/d/…` MSYS token BEFORE canonicalization, so a WRONG-DRIVE
    # reference slips (exit 0) today. Post-fix the guard is narrowed for
    # Windows-shaped tokens so the token reaches _canon and BLOCKS (wrong drive
    # → out of tree). This is the hermetic proof that a Bash-surfaced MSYS token
    # actually reaches the boundary check past the exists-guard.
    def test_win_block_msys_wrong_drive_bash(self):
        self._win_block("Bash", {"command": "cat /d/Users/u/repo/x.txt"})

    # RED today (exit 0 → NEW BLOCK): a backslash `C:\…` path is not absolute on
    # POSIX, so `_resolve` joins it UNDER the project dir and it lands in-tree →
    # wrongly ALLOWED, whether in-tree OR out-of-tree. Pins the latent
    # over-allow: an OUT-of-tree backslash path must BLOCK post-fix (the Windows
    # branch replaces the mis-firing relative-join with a canonical-key compare).
    def test_win_block_out_of_tree_backslash_read(self):
        self._win_block("Read", {"file_path": "C:\\Windows\\System32\\cmd.exe"})

    # KEEP (green today AND post-fix): an in-tree backslash path is ALLOWED
    # today by the accidental relative-join; post-fix it is ALLOWED via the
    # canonical-key compare — same end result, different code path.
    def test_win_allow_backslash_in_tree_read(self):
        self._win_allow("Read", {"file_path": "C:\\Users\\u\\repo\\sub\\x.txt"})

    # KEEP (green today AND post-fix): `git -C /c/…/repo` is ALLOWED today
    # because the `/c/…` token is DROPPED at the exists-guard (not canonicalized);
    # post-fix it is ALLOWED via _canon. Pins that narrowing the exists-guard
    # does NOT start over-blocking the in-tree MSYS repo root.
    def test_win_allow_msys_repo_root_bash_git(self):
        self._win_allow("Bash", {"command": "git -C /c/Users/u/repo status"})

    # KEEP (green-block today AND post-fix): a WRONG-TREE MSYS Read is blocked
    # today (string mismatch) and must stay blocked (canon lands out of tree).
    def test_win_block_msys_wrong_tree_read(self):
        self._win_block("Read", {"file_path": "/c/Users/u/OTHER/x.txt"})

    # KEEP (green-block today AND post-fix): a WRONG-DRIVE MSYS Read is blocked
    # today and must stay blocked post-fix.
    def test_win_block_msys_wrong_drive_read(self):
        self._win_block("Read", {"file_path": "/d/Users/u/repo/x.txt"})

    # --- Fingerprint 1: session-scratchpad allowlist -----------------------
    # RED today (exit 2): the Claude session scratchpad under Temp/claude/ is
    # outside the project boundary → over-blocked. Post-fix the `/temp/claude/`
    # session root is allowlisted → ALLOWED.
    def test_win_allow_msys_scratchpad_read(self):
        self._win_allow("Read", {"file_path": SCRATCH_MSYS})

    # KEEP (green today, red vs the Task-1 tip): the backslash scratchpad Write
    # is ALLOWED today by the accidental relative-join. After canonicalization
    # (Fingerprint 2) it would land out-of-repo and block; the scratchpad
    # allowlist (Fingerprint 1) re-allows it. Net effect: ALLOWED today AND
    # post-fix — pins that the backslash→canon path also feeds the scratchpad
    # check (a GREEN that allowlisted only the MSYS form would fail this).
    def test_win_allow_backslash_scratchpad_write(self):
        self._win_allow("Write", {"file_path": SCRATCH_BSL})

    # still-BLOCK (green-block today AND post-fix): a Temp path NOT under the
    # Temp/claude/ session root stays blocked — the allowlist is scoped to
    # Claude's own session temp root, not all of Temp.
    def test_win_block_non_claude_temp_read(self):
        self._win_block("Read", {"file_path": NON_CLAUDE_TEMP_MSYS})

    # --- Fingerprint 3: Bash token-extractor hardening ---------------------
    # RED today (exit 2): an unsubstituted `$VAR/…` prefix is scrubbed to empty,
    # surfacing the trailing `<existing-out-of-tree>/Scripts/python.exe` fragment
    # as an absolute path → over-blocked. Anchored on the existing out-of-tree
    # MIDWORD_EXISTS fixture (test_restrict_paths.py:setUpClass) so it reproduces
    # deterministically on the POSIX host. Post-fix the var-as-path-prefix scrub
    # makes the trailing `/…` mid-word → not captured → ALLOWED.
    def test_issue1153_allow_var_prefix_no_spurious_abs(self):
        cmd = 'run "$VENV' + self.MIDWORD_EXISTS + '/Scripts/python.exe" -m pytest'
        self.assertAllowed("Bash", {"command": cmd})

    # RED today (exit 2): `echo "$X/../../.."` scrubs to `/../../..`, which the
    # extractor captures and realpath-collapses to `/` → out of boundary →
    # over-blocked. Post-fix a pure relative-traversal fragment is not treated as
    # an absolute path → ALLOWED.
    def test_issue1153_allow_var_relative_dotdot(self):
        self.assertAllowed("Bash", {"command": 'echo "$X/../../.."'})

    # KEEP (green today AND post-fix): a `$VAR/…` prefix whose trailing fragment
    # does NOT exist on disk is dropped both ways (the exists-guard). Pins that
    # the standalone-`$VAR` scrub behavior is preserved.
    def test_issue1153_allow_var_prefix_nonexistent_frag(self):
        self.assertAllowed(
            "Bash", {"command": 'run "$VENV/Scripts/python.exe" -m pytest'}
        )

    # KEEP (green today AND post-fix): a quoted backslash relative traversal has
    # no `/`-leading token, so no absolute candidate is surfaced. Pins that
    # excluding backslash from the extractor token class does not start capturing
    # a backslash path token.
    def test_issue1153_allow_quoted_backslash_relative(self):
        cmd = r'cd .venv-host && "..\\..\\python.exe" --version'
        self.assertAllowed("Bash", {"command": cmd})

    # still-BLOCK (green-block today AND post-fix): a GENUINE token-boundary
    # out-of-repo absolute path (anchored on the existing MIDWORD_EXISTS fixture)
    # must stay BLOCKED — the extractor hardening must NOT widen the genuine
    # guard. (`cat /etc/passwd` and `cat //etc/passwd` are already pinned by the
    # #353/#1135 cases above.)
    def test_issue1153_block_genuine_out_of_repo_abs(self):
        cmd = "cat " + self.MIDWORD_EXISTS + "/Scripts/python.exe"
        self.assertBlocked("Bash", {"command": cmd})

    # ======================================================================
    # Issue #1188 — cd-escape: the guard has no model of the shell cwd
    # ======================================================================
    # `extract_paths()`'s Bash branch lifts only `/`-anchored ABSOLUTE tokens
    # from the command string. A `cd <anywhere>` followed by a write to a plain
    # RELATIVE path therefore leaves the project boundary with nothing for the
    # guard to extract: the string is benign, the *shell* is what makes it point
    # outside. Confirmed in the field (issue #1188): `cd ../../.. && mkdir -p
    # volumes/output/visuals/promotions` created dirs at the drive root with no
    # prompt, while the follow-up cleanup — which had to name the same location
    # ABSOLUTELY — blocked instantly.
    #
    # Post-fix the hook resolves a COMMAND-POSITION leading `cd` operand against
    # the event-payload `cwd` (only when that is itself in-boundary) or
    # PROJECT_DIR, and blocks the whole command when the target lands outside —
    # `is_allowed` is reused verbatim, so `/tmp`, `~/.claude`, sibling/nested
    # worktrees and the Windows `_canon` branch are inherited for free.
    #
    # Every case below runs against the $HOME-anchored `self.P1188` fixture, NOT
    # `self.PROJECT` (/tmp-rooted): `cd ..` out of a /tmp project lands on /tmp,
    # which the hook exempts unconditionally, so the assertion could not fail
    # for the right reason. See the fixture comment in setUpClass.

    # --- helpers ----------------------------------------------------------
    def _cd_block(self, command, **kw):
        """A #1188 NEW-BLOCK case: exits 0 TODAY (RED), must exit 2 post-fix."""
        self.assertBlocked(
            "Bash", {"command": command}, project_dir=self.P1188, **kw
        )

    def _cd_allow(self, command, **kw):
        """A #1188 ALLOW pin: green today AND post-fix."""
        self.assertAllowed(
            "Bash", {"command": command}, project_dir=self.P1188, **kw
        )

    # --- NEW BLOCKS (RED today — the hook has no cd model, all exit 0) -----
    # 1. The literal issue repro: a `..`-chain that clears the project root,
    #    then an ordinary relative mkdir. Nothing absolute anywhere.
    def test_issue1188_block_cd_dotdot_escape_relative_write(self):
        self._cd_block("cd ../../.. && mkdir -p volumes/output/visuals/promotions")

    # 2. `;` separator, single level out — the gate must not key on `&&`.
    def test_issue1188_block_cd_single_dotdot_semicolon(self):
        self._cd_block("cd ..; ls")

    # 3. `cd ~` — $HOME is outside the project boundary.
    def test_issue1188_block_cd_tilde_home(self):
        self._cd_block("cd ~ && touch f")

    # 4. The `cd` is not at position 0 — command position after `&&` counts.
    def test_issue1188_block_cd_mid_chain(self):
        self._cd_block("ls && cd ../../.. && touch x")

    # 5. Quoted operand must be dequoted before resolution.
    def test_issue1188_block_cd_quoted_target(self):
        self._cd_block('cd "../../.." && ls')

    # 6. Option words (`-P`/`-L`) are skipped; the OPERAND is the target.
    def test_issue1188_block_cd_dash_p_flag(self):
        self._cd_block("cd -P ../../.. && ls")

    # 7. Bare `cd` with no operand is `cd $HOME` in bash → out of boundary.
    def test_issue1188_block_bare_cd_no_operand(self):
        self._cd_block("cd && ls")

    # 8. The EVENT-payload `cwd` is the anchor when present and in-boundary:
    #    from <P1188>/sub/deep, `cd ../../..` resolves to dirname(P1188) →
    #    outside. Anchoring on PROJECT_DIR alone would resolve elsewhere, so
    #    this is the proof that the payload cwd is actually consulted (the hook
    #    reads only tool_name/tool_input today).
    def test_issue1188_block_cd_relative_from_payload_cwd(self):
        self._cd_block(
            "cd ../../..",
            payload_cwd=os.path.join(self.P1188, "sub", "deep"),
        )

    # 9. Windows/MSYS host shape (the reporter's `C:\volumes`): no leading `/`,
    #    so the extractor never sees it. Post-fix `_looks_windows` → `_canon`
    #    puts it out of tree. Uses the existing Windows-root simulation helper.
    def test_issue1188_block_cd_windows_backslash_root(self):
        self._win_block("Bash", {"command": "cd " + WIN_VOL + " && mkdir x"})

    # 10. The block MESSAGE must name the resolved destination and be distinct
    #     from the pre-existing path-boundary string (additive placement).
    def test_issue1188_block_message_names_resolved_dest(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": "cd ../../.. && ls"},
            project_dir=self.P1188,
        )

    # 11. POSIX `--` end-of-options: the FOLLOWING word is the operand, so it
    #     must be gated (a naive flags-only regex yields operand `--`, which
    #     joins in-project and silently fails open).
    def test_issue1188_block_cd_double_dash_terminator(self):
        self._cd_block("cd -- ../../.. && ls")

    # 12. `cd --` with nothing after is `cd $HOME`, same as bare `cd`.
    def test_issue1188_block_cd_double_dash_no_operand(self):
        self._cd_block("cd -- && ls")

    # --- ALLOW pins (green TODAY and post-fix) -----------------------------
    # These exist so the GREEN implementation cannot degrade into a blanket
    # "any cd blocks". Each is labelled with why it must stay open.

    # 13. pin (green today AND post-fix) — ordinary in-project descent.
    def test_issue1188_allow_cd_in_project_subdir(self):
        self._cd_allow("cd sub && ls")

    # 14. pin (green today AND post-fix) — `./`-prefixed in-project descent.
    def test_issue1188_allow_cd_dot_slash_subdir(self):
        self._cd_allow("cd ./sub/deep && ls")

    # 15. pin (green today AND post-fix) — the /tmp carve-out must survive; the
    #     extractor already skips /tmp candidates unconditionally and the cd
    #     gate must reach parity (mktemp-based flows depend on it, and
    #     tests/test-restrict-paths-worktree-git.sh documents the invariant).
    def test_issue1188_allow_cd_tmp(self):
        self._cd_allow("cd /tmp && ls")

    # 16. pin (green today AND post-fix) — an unsubstituted $VAR target is
    #     unresolvable → fail open. (#917 fail-open doctrine.)
    def test_issue1188_allow_cd_var_target(self):
        self._cd_allow("cd $HOME/x && ls")

    # 17. pin (green today AND post-fix) — command substitution is likewise
    #     unresolvable without running the shell → fail open.
    def test_issue1188_allow_cd_command_substitution_target(self):
        self._cd_allow('cd "$(git rev-parse --show-toplevel)" && ls')

    # 18. pin (green today AND post-fix) — `cd -` needs shell history (OLDPWD),
    #     which the hook does not have → fail open. The operand here is the
    #     literal `-`; a flags group that can match empty would eat the `-` and
    #     silently turn this into a bare-`cd` → `~` BLOCK.
    def test_issue1188_allow_cd_dash(self):
        self._cd_allow("cd - && ls")

    # 19. pin (green today AND post-fix) — the word `cd` as an ARGUMENT is not
    #     in command position. Broadening the delimiter class to quotes would
    #     re-open the #1135/#1151 false-positive family.
    def test_issue1188_allow_cd_not_command_position(self):
        self._cd_allow("echo cd ../../..")

    # 20. pin (green today AND post-fix) — a SIBLING worktree
    #     (<parent-of-project>/wt-N-slug) is allowed via WORKTREE_PATTERN, which
    #     the cd gate inherits by reusing is_allowed. This is the case that
    #     keeps in-worktree sessions workable.
    def test_issue1188_allow_cd_sibling_worktree(self):
        self._cd_allow("cd ../wt-42-x && ls")

    # 21. pin (green today AND post-fix) — the nested worktree layout
    #     (<project>/.claude/worktrees/wt-N-slug) stays reachable.
    def test_issue1188_allow_cd_nested_worktree(self):
        self._cd_allow("cd .claude/worktrees/wt-42-x && ls")

    # 22. pin (green today AND post-fix) — the payload-cwd anchor must not
    #     OVER-block: from <P1188>/sub/deep, `cd ..` is still inside P1188.
    def test_issue1188_allow_cd_relative_within_payload_cwd(self):
        self._cd_allow(
            "cd ..", payload_cwd=os.path.join(self.P1188, "sub", "deep")
        )

    # 23. pin (green today AND post-fix) — a `cd` inside a HEREDOC BODY is
    #     script TEXT being authored, not a command being run. `\n` is
    #     deliberately excluded from the command-position delimiter class so
    #     this never matches; including it would convert an everyday operation
    #     in this repo into a new over-block class (#1135/#1136/#1151/#1153 are
    #     four shipped over-block regressions on this same extractor).
    def test_issue1188_allow_cd_inside_heredoc_body(self):
        cmd = "cat > s.sh <<'EOF'\ncd ../../..\nmake\nEOF"
        self._cd_allow(cmd)

    # 24. pin (green today AND post-fix) — a `cd` on a LATER LINE of an ordinary
    #     multi-line Bash body is likewise not gated (documented residual
    #     porosity, same family as `bash -c "cd .."`). Cross-checked at the
    #     shell layer by case 7e in tests/test-restrict-paths-hook.sh.
    def test_issue1188_allow_cd_on_later_line_of_multiline_body(self):
        self._cd_allow("set -e\ncd ../..\nls")

    # --- KEEP-BLOCK pins (blocked today by the absolute-token extractor) ---
    # 25. pin (blocked today AND post-fix) — an ABSOLUTE out-of-boundary cd
    #     target already blocks via the existing extractor. The additive
    #     placement of the cd gate (LAST in the Bash flow) means this still
    #     emits the byte-identical `BLOCKED: path outside project boundary`
    #     message, so no existing stderr grep shifts.
    def test_issue1188_block_cd_absolute_etc_keep(self):
        self._cd_block("cd " + ETC + " && cat passwd")

    # 26. pin (blocked today AND post-fix) — the MSYS drive-root form is the
    #     one the reporter's cleanup command hit (`BLOCKED: path outside
    #     project boundary: /c/volumes`). It must stay blocked.
    def test_issue1188_block_cd_msys_drive_root_keep(self):
        self._win_block("Bash", {"command": "cd " + MSYS_VOL + " && mkdir x"})

    # ======================================================================
    # Issue #1190 — quoted-region masking before the cd command-position scan
    # ======================================================================
    # #1188's `_CD_RE` opens a command position after `;`, `&`, `|`, `(` or `{`
    # via a lookbehind character class with NO notion of quoting. A separator
    # sitting INSIDE a quoted string therefore opens a command position, and any
    # change-directory word that follows it is read as a real command — so
    # ordinary quoted PROSE that merely DESCRIBES directory traversal (a commit
    # message, a `printf` payload, a variable assignment) is blocked. Observed
    # live in the orchestrator session minutes after #1188 merged.
    #
    # Post-fix the hook masks quoted regions (single AND double) in a
    # LENGTH-PRESERVING copy — delimiters kept, interior replaced — scans THAT
    # copy, and slices operands from the ORIGINAL string, so the existing
    # dequote / `-` skip / `$`-backtick-glob fail-open all keep seeing real text.
    #
    # Every case runs against the $HOME-anchored `self.P1188` fixture and reuses
    # the `_cd_allow` / `_cd_block` helpers above — `self.PROJECT` is /tmp-rooted
    # and the unconditional /tmp carve-out would make each relative assertion
    # pass for the wrong reason.

    # --- RED today (exit 2, `BLOCKED: cd target outside project boundary`) ---
    # Each must become exit 0 post-fix. If any of these PASSES against the
    # unfixed hook it is vacuous — see the `..\"` operand accident noted at
    # A13 — and must be rewritten rather than trusted.

    # A1. The commit-message shape: a `;` inside `-m "…"` opens a command
    #     position and the following `cd ..` is resolved for real.
    def test_issue1190_allow_dq_commit_message_semicolon(self):
        self._cd_allow('git commit -m "narrows the scan; cd .. is misread"')

    # A2. The verbatim live-session repro from the issue body — a plain variable
    #     assignment whose value is quoted English prose, `|` as the separator.
    def test_issue1190_allow_dq_var_assignment_pipe(self):
        self._cd_allow('MSG="the cd scan| cd .. bug"')

    # A3. SINGLE-quoted payload — masking must cover `'…'`, not just `"…"`.
    def test_issue1190_allow_sq_payload_semicolon(self):
        self._cd_allow("echo 'x; cd .. done'")

    # A4. `&` member of the lookbehind class, inside quotes.
    def test_issue1190_allow_dq_ampersand_separator(self):
        self._cd_allow('echo "a && cd .. b"')

    # A5. The `(` and `{` members — a quoted shell-function snippet is the
    #     everyday shape that carries both.
    def test_issue1190_allow_dq_brace_paren_opener(self):
        self._cd_allow('echo "f() { cd .. ; }"')

    # A6. `~` operand inside quoted prose ($HOME is out of boundary, so this
    #     blocks today via the bare-`~` branch, not the `..` branch).
    def test_issue1190_allow_dq_tilde_operand(self):
        self._cd_allow('git commit -m "s; cd ~ then build"')

    # A7. A deep `..` chain inside quoted prose — the operand is a real escape
    #     shape, so only quote-awareness (not the operand grammar) can allow it.
    def test_issue1190_allow_dq_deep_chain_operand(self):
        self._cd_allow('printf %s "step; cd ../../.. then make"')

    # A8. An apostrophe INSIDE a double-quoted region must NOT open a
    #     single-quote region (which would terminate the double-quoted region
    #     early and re-expose the separator).
    def test_issue1190_allow_apostrophe_inside_dq(self):
        self._cd_allow("git commit -m \"it's; cd .. bug\"")

    # A9. A double quote nested INSIDE a single-quoted region is ordinary text.
    def test_issue1190_allow_dq_nested_in_sq(self):
        self._cd_allow("printf '%s' 'say \"x; cd .. y\"'")

    # A10. A backslash-escaped `\"` inside a double-quoted region must NOT close
    #      it — otherwise the tail is read as unquoted and the separator fires.
    def test_issue1190_allow_escaped_dq_inside_dq(self):
        self._cd_allow(r'echo "a \" b; cd .. c"')

    # A11. A REAL newline inside the quoted region: the mask must stay
    #      line-aligned with the original (newline preserved, not replaced), and
    #      the region must span the newline the way the shell does.
    def test_issue1190_allow_multiline_quoted_prose(self):
        self._cd_allow('echo "line1; cd ..\nline2"')

    # A14. ADJACENT quoted regions glued into one shell word (`"a"b"c…"`): the
    #      separator lives in the SECOND region. A naive "strip from the first
    #      quote to the last quote" mask happens to allow this too, but a mask
    #      that toggles state per delimiter is the only one that also keeps K1–K3
    #      blocking. (Evaluator recommendation 3 on the approved plan.)
    def test_issue1190_allow_adjacent_quoted_regions(self):
        self._cd_allow('echo "a"b"c; cd .. done"')

    # --- NON-RED allow pins (green TODAY and post-fix) ---------------------

    # A12. The quoted variant of `test_issue1188_allow_cd_var_target`: a quoted
    #      `$VAR` operand is unresolvable without shell state → fail open.
    #      NOT a discriminator for operand-slicing (a masked-copy slice yields
    #      `xxxxxxxx`, which joins IN-project and still exits 0) — that failure
    #      mode is pinned by K3 + `test_issue1188_block_cd_quoted_target`, which
    #      both flip to ALLOW under a masked-copy slice. Kept as the fail-open
    #      pin it actually is.
    def test_issue1190_allow_quoted_var_operand(self):
        self._cd_allow('cd "$HOME/x" && ls')

    # A13. Green TODAY only by ACCIDENT, and green post-fix for the right
    #      reason. `_CD_RE`'s unquoted-operand class `[^\s;&|<>]+` does not
    #      exclude quote chars, so the operand here is captured as `..\"` — one
    #      nonexistent IN-project component that resolves in-boundary. Do not
    #      mistake this shape for quote coverage: append any word after the `..`
    #      (A3, A14) and the same string blocks. Labelled non-RED so the red
    #      author does not chase a phantom failure.
    def test_issue1190_allow_operand_at_end_of_quote(self):
        self._cd_allow('echo "x; cd .."')

    # --- KEEP-BLOCK guards (blocked TODAY, must stay blocked post-fix) -----
    # The anti-under-block floor. A fix that reintroduces any escape shape is
    # worse than the false positive it removes, so each of these is an
    # adversarial shape a sloppy mask would break.

    # K1. A REAL leading `cd` escape with a DECOY quoted region after it: the
    #     mask must not let the decoy suppress the genuine command position.
    def test_issue1190_block_real_cd_with_decoy_quoted_region(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": 'cd .. && echo "; cd /safe"'},
            project_dir=self.P1188,
        )

    # K2. A real `cd` escape AFTER a balanced quoted region: masking must be
    #     length-preserving, or the spans shift and the tail is mis-sliced.
    def test_issue1190_block_real_cd_after_quoted_region(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": 'echo "note" ; cd ../../.. && ls'},
            project_dir=self.P1188,
        )

    # K3. A quoted TARGET after a quoted region — #1188 case 5 in the presence
    #     of masking. Survives only if the mask preserves the quote DELIMITERS
    #     (so `_CD_RE`'s `"[^"]*"` alternative still matches) AND the operand is
    #     sliced from the ORIGINAL string (so the dequote sees `../../..`, not
    #     `xxxxxxxx`). This case + `test_issue1188_block_cd_quoted_target` are
    #     what actually pin the masked-copy-slice failure mode.
    def test_issue1190_block_quoted_target_after_quoted_region(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": 'echo "note" && cd "../../.."'},
            project_dir=self.P1188,
        )

    # K4. UNTERMINATED double quote → fail CLOSED: the scan must fall back to
    #     the RAW command (today's #1188 behavior, never fewer blocks).
    #     Masking to end-of-string would hand over a one-character bypass.
    def test_issue1190_block_unterminated_dq_fails_closed(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": 'echo "oops; cd ../../..'},
            project_dir=self.P1188,
        )

    # K5. Same, single quote.
    def test_issue1190_block_unterminated_sq_fails_closed(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": "echo 'oops; cd ../../.."},
            project_dir=self.P1188,
        )

    # K6. A BACKSLASH-ESCAPED quote OUTSIDE any quoted region must not open a
    #     region — otherwise the real, unquoted escape that follows is masked
    #     away and silently allowed.
    def test_issue1190_block_escaped_quote_outside_quotes(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": r"echo don\'t ; cd ../../.."},
            project_dir=self.P1188,
        )

    # K7. SCOPE GUARD for where the mask may live. `extract_paths()` scans a
    #     DIFFERENT string (the `$VAR`-scrubbed copy) with a token-boundary class
    #     that deliberately INCLUDES the quote chars — which is exactly why a
    #     quoted absolute out-of-boundary token blocks today. Masking that string
    #     (or hoisting one shared masked copy) would blind the extractor to every
    #     quoted absolute path. The mask must stay inside the cd path, and this
    #     command must keep emitting the PATH message, not the cd one.
    def test_issue1190_block_quoted_absolute_path_scope_guard(self):
        self.assertBlockedWith(
            PATH_BLOCK_MSG, "Bash", {"command": 'cat "' + ETC + '/passwd"'},
            project_dir=self.P1188,
        )


    # ======================================================================
    # Issue #1192 — nested shell strings, heredoc bodies, ANSI-C quoting
    # ======================================================================
    # Three residuals the #1188 cd gate and the #1190 quote mask leave behind,
    # surfaced by the differential drive on PR #1191:
    #
    #   shape 1 — `bash -c "cd …"`: a real UNDER-block. The inner shell string
    #             is masked as an ordinary quoted region, so the
    #             change-directory command inside it is never scanned.
    #   shape 2 — heredoc BODIES: manifests today as an OVER-block. #1188
    #             dropped `\n` from the command-position class, but not `;`, so
    #             a body line reading `echo a; cd ..` still opens a command
    #             position; and a protected-looking token in a body still trips
    #             the protected-write scan.
    #   shape 3 — `$'…'` ANSI-C quoting: also an OVER-block today. The mask does
    #             not know the `$'` opener, so an escaped `\'` inside the region
    #             closes it early and re-exposes the tail as unquoted text.
    #
    # The direction of each change is deliberately partitioned, so a regression
    # in either direction is attributable to one commit: the ANSI-C and heredoc
    # cases can only REMOVE blocks; the nested `-c` scan can only ADD them. Per
    # #1190 every new block case is paired with an allow case.
    #
    # Shared authoring conventions for every case below:
    #   * operands use `UP7` (a seven-deep `..` chain) — a 1-deep `..` can land
    #     back in-boundary and pass vacuously;
    #   * the project fixture is `self.P1188` via `_cd_allow` / `_cd_block`;
    #     `self.PROJECT` is /tmp-rooted and the unconditional /tmp carve-out
    #     would make every relative-`cd` assertion pass for the wrong reason;
    #   * protected / absolute literals are built from the `SET` / `HK` / `ETC`
    #     fragments so this test SOURCE never carries one verbatim.

    # --- Task 1: ANSI-C quoting (`$'…'`), shape 3 -------------------------
    # REMOVAL-ONLY. `_mask_quoted_regions` must learn the `$'` opener, inside
    # which a backslash escapes the following character (POSIX `$'…'`
    # semantics), unlike a plain `'…'` region where a backslash is literal.

    # RED today (exit 2, CD_BLOCK_MSG): the `\'` closes the region early, so the
    # tail `b ; cd <UP7>'` is scanned as unquoted text and the `;` opens a
    # command position. The operand the gate reports reads `<UP7>'` — the
    # trailing quote is the tell that the region ended in the wrong place.
    def test_issue1192_allow_ansi_c_escaped_quote_prose(self):
        self._cd_allow(r"echo $'a\'b ; cd " + UP7 + "'")

    # KEEP-BLOCK (blocked today AND post-fix): the same ANSI-C region, CLOSED
    # before the separator — the `cd` that follows is a genuine command position
    # and must stay blocked. This is the pin that stops the Task-1 fix from
    # degrading into "everything after a `$'` is quoted".
    def test_issue1192_block_ansi_c_real_escape_after_close(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": r"echo $'a\'b' ; cd " + UP7},
            project_dir=self.P1188,
        )

    # KEEP-BLOCK: the simplest closed-then-real-cd shape, with no escape inside
    # the region at all.
    def test_issue1192_block_ansi_c_closed_then_real_cd(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash", {"command": "echo $'x' ; cd " + UP7},
            project_dir=self.P1188,
        )

    # KEEP-ALLOW (green today AND post-fix): an ANSI-C region with no escape
    # inside it is already covered — the plain `'` opener masks it. Pinned so
    # the new `$'` arm cannot regress the shape it is grafted onto.
    def test_issue1192_allow_ansi_c_plain_no_escape(self):
        self._cd_allow("echo $'x ; cd " + UP7 + "'")

    # --- Task 2: heredoc bodies are DATA, shape 2 -------------------------
    # REMOVAL-ONLY. A heredoc body is stdin DATA, not a command being run — so
    # it is masked out of the cd scan AND the protected-write scan. The single
    # exception is a body owned by an INTERPRETER command word (`bash`, `sh`,
    # `python`, … reached through `env`/`nohup`-style wrappers): that body IS
    # executed and stays scanned, fail closed.

    # RED today (exit 2, CD_BLOCK_MSG): authoring a shell script with a heredoc
    # is an everyday operation in this repo; the `;` on the body line currently
    # opens a command position.
    def test_issue1192_allow_heredoc_body_semicolon_cd(self):
        self._cd_allow("cat > s.sh <<'EOF'\necho a; cd " + UP7 + "\nEOF")

    # RED today: the same shape with a longer filename. This is the regression
    # pin for the interpreter carve-out — `\bsh\b` MATCHES inside `script.sh`
    # (the `.` supplies a word boundary), so a line-wide search for an
    # interpreter word would exempt exactly the shape this task exists to fix.
    # The carve-out must key on the segment's COMMAND WORD (`cat`), never a
    # line-wide search.
    def test_issue1192_allow_heredoc_body_dot_sh_name_not_interpreter(self):
        self._cd_allow("cat > script.sh <<'EOF'\necho a; cd " + UP7 + "\nEOF")

    # RED today: an apostrophe in ordinary body prose leaves the quote scanner
    # unterminated, so `_mask_quoted_regions` returns None and the RAW command
    # is scanned — the #1190 fail-closed path. Masking the body FIRST is what
    # removes the stray apostrophe before the quote scanner ever sees it.
    def test_issue1192_allow_heredoc_body_unbalanced_apostrophe(self):
        self._cd_allow("cat > s.sh <<'EOF'\ndon't stop; cd " + UP7 + "\nEOF")

    # RED today: the `<<-` tab-stripping form, whose terminator line may be
    # indented with tabs. A masker that compares the terminator line verbatim
    # would never find the end and would mask the rest of the command.
    def test_issue1192_allow_heredoc_dash_tab_terminator(self):
        self._cd_allow("cat > s.sh <<-'EOF'\n\techo a; cd " + UP7 + "\n\tEOF")

    # RED today: TWO heredocs opened on ONE line. Bash reads their bodies in
    # order, so the masker needs a FIFO queue of pending delimiters, not a
    # single pending one.
    def test_issue1192_allow_heredoc_two_bodies_one_line(self):
        self._cd_allow(
            "cat > a.txt <<'A' > " + DEVNULL + " <<'B'\nx; cd " + UP7
            + "\nA\ny\nB"
        )

    # RED today: an UNTERMINATED body (no terminator line at all) is still all
    # body — the mask must run to end-of-string rather than giving up.
    def test_issue1192_allow_heredoc_unterminated_body(self):
        self._cd_allow("cat > s.sh <<'EOF'\necho a; cd " + UP7)

    # RED today (exit 2, PROT_BLOCK_MSG — NOT the cd message): the second half
    # of shape 2. Authoring HTML/prose whose text merely NAMES the protected
    # hooks dir currently trips `_protected_write_context`, because the `>`
    # redirect and the protected-looking token share one command string. The
    # body is data, so the protected-write scan must not see it either.
    def test_issue1192_allow_heredoc_body_protected_token_html(self):
        cmd = (
            'cat > out.html <<EOF\n<span class="path">' + HK
            + 'x.py</span>\nEOF'
        )
        self.assertAllowed("Bash", {"command": cmd}, project_dir=self.P1188)

    # KEEP-BLOCK (blocked today AND post-fix) — the interpreter carve-out. A
    # body fed to a shell on stdin IS executed, so it stays scanned.
    def test_issue1192_block_heredoc_fed_to_bash(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # KEEP-BLOCK: same, `sh` with a QUOTED delimiter.
    def test_issue1192_block_heredoc_fed_to_sh(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "sh <<'EOF'\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # KEEP-BLOCK: the interpreter reached through an `env` wrapper plus a
    # `NAME=value` assignment — the command-word resolver must skip both.
    def test_issue1192_block_heredoc_fed_to_bash_via_env_wrapper(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "env FOO=1 bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # KEEP-BLOCK: the interpreter is the command word of the LAST pipeline
    # segment, not of the line — a resolver that reads the first word of the
    # line would see `echo` and wrongly mask this body.
    def test_issue1192_block_heredoc_fed_to_bash_after_pipe(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "echo x | bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # KEEP-BLOCK: the heredoc OPERATOR line is a real command line. A `cd`
    # after a `;` on that line is a genuine command position and must survive —
    # the mask starts at the NEXT line, not at the operator.
    def test_issue1192_block_cd_on_heredoc_operator_line(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "cat <<EOF > s.txt; cd " + UP7 + "\nhi\nEOF"},
            project_dir=self.P1188,
        )

    # KEEP-BLOCK, non-vacuous: a real escape AFTER the terminator line. A mask
    # that over-runs the terminator (never pops the queue) flips this to exit 0,
    # so it is the pin for the body-end boundary.
    def test_issue1192_block_cd_after_heredoc_terminator(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "cat > s.sh <<'EOF'\nhi\nEOF\ntrue; cd " + UP7},
            project_dir=self.P1188,
        )

    # KEEP-BLOCK, non-vacuous only in this MULTI-LINE form: a HERESTRING
    # (`<<<`) opens no body at all. An operator regex of `<<(?!<)` still matches
    # at offset 1 of `<<<`, takes `x` as the delimiter, and masks every
    # following line — flipping this to exit 0. The lookBEHIND `(?<!<)` is what
    # keeps it blocked. A single-line herestring pin is exit 2 under BOTH
    # regexes and would prove nothing.
    def test_issue1192_block_herestring_multiline_not_heredoc(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'cat <<< "x"\ntrue; cd ' + UP7},
            project_dir=self.P1188,
        )

    # KEEP-BLOCK: a REAL redirect into a protected control file on the heredoc
    # OPERATOR line still blocks with the protected-write message. Masking the
    # body must not blind the guard to the write it is actually performing.
    def test_issue1192_block_redirect_protected_before_heredoc(self):
        self.assertBlockedWith(
            PROT_BLOCK_MSG, "Bash",
            {"command": "cat > " + SET + " <<EOF\nhi\nEOF"},
        )

    # KEEP-BLOCK — SCOPE GUARD, the #1190 K7 discipline restated for the new
    # mask. `extract_paths()` scans a DIFFERENT string and must never see the
    # heredoc mask: a body naming an ABSOLUTE out-of-boundary token still emits
    # the PATH message, not the cd one. This is also why the operational-notes
    # amendment for this issue is narrow — `--body-file` stays the workaround
    # for absolute-looking tokens even inside a heredoc body.
    def test_issue1192_block_heredoc_body_absolute_token_scope_guard(self):
        self.assertBlockedWith(
            PATH_BLOCK_MSG, "Bash",
            {"command": "cat > s.txt <<'EOF'\nsee " + ETC + "/passwd here\nEOF"},
            project_dir=self.P1188,
        )

    # KEEP-ALLOW (green today AND post-fix): pin 23's shape restated under the
    # new masker — a body line that STARTS with `cd` was already open because
    # `\n` is not in the command-position class, and must stay open.
    def test_issue1192_allow_heredoc_body_line_start_cd(self):
        self._cd_allow("cat > s.sh <<'EOF'\ncd " + UP7 + "\nmake\nEOF")

    # --- Task 3: one level into a nested `-c` shell string, shape 1 -------
    # ADDITION-ONLY. A recognized `<shell> -c '<fully quoted string>'` is
    # scanned ONE level deep. The recognizer requires a known shell word AND a
    # `c`-bearing flag AND a fully quoted argument, and it runs over the MASKED
    # copy — so quoted prose that merely NAMES the shape is not a command
    # position (that is the #1190 over-block class, verbatim).

    # RED today (exit 0): the literal shape from the issue.
    def test_issue1192_block_bash_c_nested_cd_escape(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'bash -c "cd ' + UP7 + ' && mkdir x"'},
            project_dir=self.P1188,
        )

    # RED today: the inner `cd` is not first — the inner scan must be a full
    # command-position scan, not a "starts with cd" test.
    def test_issue1192_block_bash_c_nested_after_separator(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'bash -c "true; cd ' + UP7 + ' && mkdir x"'},
            project_dir=self.P1188,
        )

    # RED today: `sh` as the shell word. `\bsh\b` must match here and must NOT
    # match inside `ssh` (there is no word boundary between the two `s`).
    def test_issue1192_block_sh_c_nested_cd_escape(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'sh -c "cd ' + UP7 + ' && ls"'},
            project_dir=self.P1188,
        )

    # RED today: reached through an `env` wrapper with an assignment.
    def test_issue1192_block_env_bash_c_nested(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'env FOO=1 bash -c "cd ' + UP7 + ' && ls"'},
            project_dir=self.P1188,
        )

    # RED today: the `ssh <host> bash -c "…"` form — bare `ssh` stays allowed
    # (see the pin below), but an explicit shell word carrying a `-c` flag is
    # the recognized shape wherever it appears.
    def test_issue1192_block_ssh_bash_c_nested(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'ssh h bash -c "cd ' + UP7 + ' && ls"'},
            project_dir=self.P1188,
        )

    # RED today: GLUED flag letters (`-lc`). A recognizer keyed on the exact
    # token `-c` misses this.
    def test_issue1192_block_bash_lc_glued_flag(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'bash -lc "cd ' + UP7 + '"'},
            project_dir=self.P1188,
        )

    # RED today: a SINGLE-quoted `-c` argument, the more idiomatic form.
    def test_issue1192_block_bash_c_single_quoted_arg(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "bash -c 'cd " + UP7 + " && ls'"},
            project_dir=self.P1188,
        )

    # KEEP-ALLOW (green today AND post-fix) — the anti-false-positive floor.

    # `ssh host "cd …"` carries NO `-c` flag and is named in the hook docstring
    # as a member of the #1135/#1151 false-positive family. Deliberately out of
    # scope; requiring a `c`-bearing flag is what keeps it open.
    def test_issue1192_allow_ssh_bare_quoted_cd(self):
        self._cd_allow('ssh h "cd ' + UP7 + ' && ls"')

    # A `-c` flag on a NON-shell command word (`ssh -c <cipher>`) must not turn
    # the trailing quoted string into a shell script.
    def test_issue1192_allow_ssh_dash_c_cipher_flag(self):
        self._cd_allow('ssh -c aes128-ctr h "cd ' + UP7 + ' && ls"')

    # Same for `git -c key=value` — `git` is not a shell word, so its `-c` is
    # unaffected. This is the most common `-c` in this repo.
    def test_issue1192_allow_git_dash_c_config(self):
        self._cd_allow('git -c user.name=x commit -m "a; cd ' + UP7 + '"')

    # A nested `-c` whose target is IN-project is an ordinary operation.
    def test_issue1192_allow_bash_c_in_project_target(self):
        self._cd_allow('bash -c "cd sub && ls"')

    # The inner string inherits quote masking: a decoy `cd` inside a quoted
    # region of the inner script is not a command position at depth 1 either.
    def test_issue1192_allow_bash_c_quoted_decoy_inside(self):
        self._cd_allow("bash -c \"echo 'z; cd " + UP7 + "'\"")

    # The inner string inherits the `$VAR` fail-open (#917 doctrine).
    def test_issue1192_allow_bash_c_var_target(self):
        self._cd_allow('bash -c "cd $WORKTREE && ls"')

    # The DOCUMENTED depth cap: depth-2 nesting is explicitly out of scope.
    # Recursively parsing arbitrary nested shell strings is the unbounded work
    # #1188 ruled out; this pin is what keeps the cap deliberate.
    def test_issue1192_allow_bash_c_depth_two(self):
        self._cd_allow("bash -c \"bash -c 'cd " + UP7 + "'\"")

    # An UNTERMINATED inner quote is not a fully quoted argument — the
    # recognizer requires one, so this falls open rather than guessing where the
    # argument ends.
    def test_issue1192_allow_bash_c_unterminated_inner(self):
        self._cd_allow('bash -c "cd ' + UP7)

    # The three PROSE pins: text that merely NAMES the nested-shell shape must
    # stay allowed. Running the recognizer over the ORIGINAL command string
    # instead of the masked copy re-opens the #1190 over-block class verbatim,
    # and these are the cases that catch it.
    def test_issue1192_allow_nested_shell_shape_in_commit_message(self):
        self._cd_allow(
            'git commit -m "note: bash -c \'cd ' + UP7 + '\' escapes"'
        )

    def test_issue1192_allow_nested_shell_shape_in_gh_body(self):
        self._cd_allow(
            'gh issue comment 9 --body "shape: sh -c \'cd ' + UP7
            + '\' is an escape"'
        )

    # …including inside a heredoc body, where Task 2's mask and Task 3's
    # recognizer compose.
    def test_issue1192_allow_nested_shell_shape_in_heredoc_body(self):
        self._cd_allow("cat > s.sh <<'EOF'\nbash -c \"cd " + UP7 + "\"\nEOF")

    # ======================================================================
    # Issue #1194 — wrapper ARITY, arithmetic `<<`, and POSIX `--`
    # ======================================================================
    # Three residuals the #1192 heredoc mask and nested-shell recognizer leave
    # behind, surfaced by the differential drive on PR #1193:
    #
    #   shape 1 — a WRAPPER word whose argument is POSITIONAL (or a separate
    #             option argument) defeats the interpreter carve-out.
    #             `_segment_command_word` skips `NAME=value`, `-`-leading
    #             flags, and `_WRAPPER_WORDS`, then returns the FIRST survivor
    #             — so `timeout 300 bash <<EOF` resolves to `300`, not `bash`,
    #             and a body that IS executed gets masked as DATA. A real
    #             UNDER-block, in both the cd scan and the protected-write
    #             scan. `nice` is not in `_WRAPPER_WORDS` at all.
    #   shape 2 — an arithmetic left-shift is read as a heredoc OPERATOR.
    #             `_HEREDOC_OP_RE` matches `<<` whose RHS is an identifier, so
    #             `echo $((x << y))` opens a phantom heredoc with delimiter
    #             `y` and masks every following line. Also a real UNDER-block.
    #             A numeric RHS (`$((1 << 2))`) never matched — `2` fails the
    #             `[A-Za-z_]` class — so that shape is a keep-BLOCK, not a fix.
    #   shape 3b — POSIX `--` end-of-options. `_NESTED_SHELL_RE`'s flag group
    #             `[A-Za-z-]+` accepts a lone `-`, so `--` is absorbed as a
    #             flag and the following `-c` still matches — but after a `--`
    #             the `-c` is a script FILENAME and no `cd` runs. An
    #             OVER-block.
    #
    # Direction of change, partitioned per commit so a regression is
    # attributable: shape 1 and shape 2 can only ADD blocks; shape 3b can only
    # REMOVE them. Shape 3a (`echo bash -c "cd …"`, an unquoted PROSE mention)
    # is DOCUMENTED, not fixed — a command-position anchor on
    # `_NESTED_SHELL_RE` was measured to drop SEVEN wrapper-reached shapes
    # (`xargs`/`find -exec`/`ssh host`/`timeout 5`/`sudo`/`env`/`nohup` +
    # `bash -c`) from exit 2 to exit 0, four of them the very shapes shape 1
    # exists to protect. It is pinned below as a keep-BLOCK so the trade-off
    # stays deliberate.
    #
    # Three KINDS of pin live in this section; the labels matter when reading a
    # failure:
    #   * BLOCK / ALLOW pins that are RED at HEAD — the new behavior.
    #   * KEEP-BLOCK pins for the FLIP class — green at HEAD, and green
    #     post-fix ONLY IF the arity walk carries the interpreter guard. They
    #     are the executable statement that no token which basenames to an
    #     `_INTERP_WORD_RE` word is ever consumed as someone else's option
    #     argument or positional. An UNguarded arity walk turns all seven red.
    #   * PAIRED ALLOW pins — the #1190 guard: every new block ships with an
    #     allow that must stay open.
    #
    # Shared authoring conventions are #1192's, unchanged: `UP7` operands,
    # the `self.P1188` $HOME-anchored fixture, and protected literals built
    # from the `SET` fragment.

    # --- Task 1: wrapper arity + the interpreter guard, shape 1 -----------
    # ADDITION-ONLY. `_segment_command_word` gains a per-wrapper arity model
    # (`_WRAPPER_ARG_OPTS` — options that consume a SEPARATE following token;
    # `_WRAPPER_POSITIONALS` — positionals consumed before the command word,
    # `timeout: 1`, every other wrapper 0) plus the interpreter guard.

    # RED today (exit 0): the literal issue repro. `timeout`'s duration is a
    # positional, so the walk terminates on `300` and never reaches `bash`.
    def test_issue1194_block_heredoc_timeout_duration_positional(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "timeout 300 bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: `-k` takes a SEPARATE argument AND the duration positional
    # still follows — two tokens to step over before `bash`.
    def test_issue1194_block_heredoc_timeout_k_and_duration(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "timeout -k 5 30 bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: the same shape with a NON-numeric option argument, so the fix
    # cannot degrade into "skip a token that looks like a number".
    def test_issue1194_block_heredoc_timeout_s_signal_and_duration(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "timeout -s KILL 30 bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: `sudo -u <user>` — a zero-positional wrapper whose option
    # argument is the token the walk currently returns.
    def test_issue1194_block_heredoc_sudo_u_user(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "sudo -u root bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: `nice` is absent from `_WRAPPER_WORDS` entirely, so the walk
    # stops on `nice` itself — and `-n 5` would stop it again once added.
    def test_issue1194_block_heredoc_nice_n_adjustment(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "nice -n 5 bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: bare `nice` with no options — the membership half of the fix,
    # isolated from the arity half.
    def test_issue1194_block_heredoc_nice_bare_wrapper(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "nice bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: `env -u NAME` — the SPACED form of an option `env` already
    # models in its glued `--unset=NAME` spelling.
    def test_issue1194_block_heredoc_env_u_unset(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "env -u FOO bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: `stdbuf -o L` spaced. The GLUED spelling `-oL` already
    # resolves correctly today, which is why the arg-option match must be an
    # EXACT token compare rather than a prefix test.
    def test_issue1194_block_heredoc_stdbuf_o_separate_arg(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "stdbuf -o L bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: a LONG no-argument flag plus the duration positional — the
    # valid form of the flip-class shape pinned as a keep-BLOCK below.
    def test_issue1194_block_heredoc_timeout_long_flag_and_duration(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "timeout --preserve-status 30 bash <<EOF\ntrue; cd "
                        + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today (exit 0, PROT message post-fix — NOT the cd one): the second
    # scan wired to the heredoc mask. A body that writes a protected control
    # file IS executed under a wrapper-reached interpreter.
    def test_issue1194_block_heredoc_timeout_protected_write(self):
        self.assertBlockedWith(
            PROT_BLOCK_MSG, "Bash",
            {"command": "timeout 300 bash <<EOF\necho x > " + SET + "\nEOF"},
            project_dir=self.P1188,
        )

    # RED today: same, through the zero-positional `sudo -u` shape.
    def test_issue1194_block_heredoc_sudo_protected_write(self):
        self.assertBlockedWith(
            PROT_BLOCK_MSG, "Bash",
            {"command": "sudo -u root bash <<EOF\necho x > " + SET + "\nEOF"},
            project_dir=self.P1188,
        )

    # --- Task 1 KEEP-BLOCK pins: the flip-class interpreter guard ---------
    # All seven are green at HEAD. They go RED against an arity walk that
    # lacks the interpreter guard, because the token the walk newly consumes
    # IS the interpreter — a block silently becoming an allow. `env -S bash`
    # is the genuine escape of the group (it really does exec bash); the
    # `timeout` rows are invalid invocations, but a silent regression either
    # way. Measured: HEAD 2 → unguarded 0 → guarded 2.

    # `env -S <command>` really execs its argument, so `bash` here is the
    # interpreter, not an option argument to be stepped over.
    def test_issue1194_keepblock_env_dash_s_bash(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "env -S bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # The same escape with `env -S`'s split-string spelling — the interpreter
    # word is QUOTED and carries its own flag, so the guard's basename step
    # (`tok.strip("\"'").rsplit("/", 1)[-1]`) has to run before the compare.
    def test_issue1194_keepblock_env_dash_s_quoted_bash_x(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'env -S "bash -x" <<EOF\ntrue; cd ' + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # The flip class restated on the protected-write scan, so the guard is
    # pinned on BOTH consumers of the heredoc mask.
    def test_issue1194_keepblock_env_dash_s_bash_protected_write(self):
        self.assertBlockedWith(
            PROT_BLOCK_MSG, "Bash",
            {"command": "env -S bash <<EOF\necho x > " + SET + "\nEOF"},
            project_dir=self.P1188,
        )

    # `timeout --preserve-status` with NO duration: the 1-positional budget is
    # still pending when `bash` arrives, so the positional arm is the one the
    # guard has to protect here (contrast with `-v` below, the option arm).
    def test_issue1194_keepblock_timeout_preserve_status_bash(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "timeout --preserve-status bash <<EOF\ntrue; cd "
                        + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # Short-flag spelling of the same pending-positional shape.
    def test_issue1194_keepblock_timeout_v_bash(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "timeout -v bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # `sudo -u bash id` — `bash` sits exactly where `sudo`'s `-u` argument
    # goes. The guard refuses to consume it, so the walk returns `bash` and
    # this stays blocked (fail closed on an ambiguous shape).
    def test_issue1194_keepblock_sudo_u_bash_id(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "sudo -u bash id <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # Same shape on `stdbuf -o`, whose argument is a buffering mode.
    def test_issue1194_keepblock_stdbuf_o_bash(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "stdbuf -o bash <<EOF\ntrue; cd " + UP7 + "\nEOF"},
            project_dir=self.P1188,
        )

    # --- Task 1 PAIRED ALLOW pins (the #1190 guard) -----------------------
    # Green at HEAD AND post-fix. A wrapper-reached NON-interpreter still owns
    # a DATA body, and the everyday `cat > file <<EOF` idiom stays open.

    def test_issue1194_allow_timeout_duration_cat_heredoc(self):
        self._cd_allow("timeout 300 cat > s.txt <<EOF\ntrue; cd " + UP7 + "\nEOF")

    def test_issue1194_allow_nice_adjustment_cat_heredoc(self):
        self._cd_allow("nice -n 5 cat > s.txt <<EOF\ntrue; cd " + UP7 + "\nEOF")

    def test_issue1194_allow_sudo_user_tee_heredoc(self):
        self._cd_allow("sudo -u root tee s.txt <<EOF\ntrue; cd " + UP7 + "\nEOF")

    # The next three are the option-(b)-rejection guard. "Any token in the
    # segment that basenames to an interpreter word" would flip all of them to
    # exit 2 — the #1190 over-block class reopened on the most common heredoc
    # idiom in this repo. The interpreter guard must never PROMOTE a
    # non-command-position token to the command word, only refuse to CONSUME
    # one as somebody else's argument.
    def test_issue1194_allow_echo_bash_heredoc(self):
        self._cd_allow("echo bash <<EOF\ntrue; cd " + UP7 + "\nEOF")

    def test_issue1194_allow_grep_bash_heredoc(self):
        self._cd_allow("grep bash <<EOF\ntrue; cd " + UP7 + "\nEOF")

    def test_issue1194_allow_timeout_grep_bash_heredoc(self):
        self._cd_allow("timeout 30 grep bash <<EOF\ntrue; cd " + UP7 + "\nEOF")

    # The protected-write half of the paired-allow guard: prose in a DATA body
    # that merely NAMES a protected control file stays open.
    def test_issue1194_allow_timeout_cat_protected_prose_heredoc(self):
        self.assertAllowed(
            "Bash",
            {"command": "timeout 5 cat > s.txt <<EOF\nedit " + SET
                        + " by hand\nEOF"},
            project_dir=self.P1188,
        )

    # The paired allows for the two NEW guard classes: an `env -S` whose
    # argument is NOT an interpreter, and a `timeout` long flag whose
    # positional is consumed by an ordinary command.
    def test_issue1194_allow_env_dash_s_echo_heredoc(self):
        self._cd_allow("env -S echo <<EOF\ntrue; cd " + UP7 + "\nEOF")

    def test_issue1194_allow_timeout_preserve_status_cat_heredoc(self):
        self._cd_allow(
            "timeout --preserve-status cat > s.txt <<EOF\ntrue; cd " + UP7
            + "\nEOF"
        )

    # --- Task 2: arithmetic `<<` is not a heredoc operator, shape 2 -------
    # ADDITION-ONLY. A new `_mask_arith_regions(line)` blanks the interior of
    # `$(( … ))` (any position) and of `(( … ))` (command position only —
    # start of line, or after `;&|(){`, or after `if|while|until|elif|then|do`)
    # before `_HEREDOC_OP_RE` probes the line, so a left-shift never queues a
    # phantom delimiter. Narrowing the operator recognizer can only recognize
    # FEWER heredocs, i.e. mask FEWER bodies, i.e. scan MORE — fail closed.

    # RED today (exit 0): the literal shape. `y` satisfies `[A-Za-z_]`, so
    # `<< y` queues a phantom heredoc and the whole next line is masked.
    def test_issue1194_block_arith_shift_then_cd(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "echo $((x << y))\ntrue; cd " + UP7},
            project_dir=self.P1188,
        )

    # RED today: the protected-write half — the phantom body swallows a real
    # redirect into a control file.
    def test_issue1194_block_arith_shift_then_protected_write(self):
        self.assertBlockedWith(
            PROT_BLOCK_MSG, "Bash",
            {"command": "echo $((x << y))\necho x > " + SET},
            project_dir=self.P1188,
        )

    # RED today: no spaces around the operator, inside an assignment — the
    # mask must key on the `$((`/`))` region, not on surrounding whitespace.
    def test_issue1194_block_arith_shift_in_assignment_then_cd(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "x=$((a<<b))\ntrue; cd " + UP7},
            project_dir=self.P1188,
        )

    # RED today: the bare `(( … ))` arithmetic COMMAND at start of line.
    def test_issue1194_block_bare_arith_command_then_cd(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "((x << y))\ntrue; cd " + UP7},
            project_dir=self.P1188,
        )

    # RED today: `((` after the `if` keyword — the command-position anchor for
    # the bare form has to admit the keyword prefixes, not just `^` and the
    # `;&|(){` class.
    def test_issue1194_block_arith_shift_in_if_then_cd(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "if ((a << b)); then :; fi\ntrue; cd " + UP7},
            project_dir=self.P1188,
        )

    # --- Task 2 keep pins -------------------------------------------------

    # KEEP-ALLOW: a REAL heredoc on a later line still masks its body. The
    # arithmetic mask is applied to the operator PROBE only — the delimiter is
    # still sliced from the ORIGINAL line and `_segment_command_word` still
    # walks the raw prefix.
    def test_issue1194_allow_numeric_shift_then_real_heredoc(self):
        self._cd_allow(
            "echo $((1 << 2))\ncat <<EOF\ntrue; cd " + UP7 + "\nEOF"
        )

    # KEEP-ALLOW: a heredoc opened inside a SUBSHELL. `(cat <<EOF` has a
    # single `(`, so the command-position `((` arm must not fire on it — the
    # body stays masked and this stays open.
    def test_issue1194_allow_subshell_heredoc_still_masked(self):
        self._cd_allow("(cat <<EOF\ntrue; cd " + UP7 + "\nEOF\n)")

    # KEEP-ALLOW: an ordinary arithmetic COMPARISON (single `<`) on a line
    # before a real heredoc. Masking the `(( … ))` interior must not disturb
    # the following line's real operator.
    def test_issue1194_allow_arith_compare_then_real_heredoc(self):
        self._cd_allow(
            "if ((n < 2)); then :; fi\ncat <<EOF\ntrue; cd " + UP7 + "\nEOF"
        )

    # KEEP-BLOCK: a NUMERIC right-hand side was never a phantom operator (`2`
    # fails `_HEREDOC_OP_RE`'s `[A-Za-z_]` class), so this line already leaves
    # the next line scanned and must keep doing so. The pin that stops the
    # arithmetic mask from being mistaken for a change in this direction.
    def test_issue1194_keepblock_numeric_shift_then_cd(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": "echo $((1 << 2))\ntrue; cd " + UP7},
            project_dir=self.P1188,
        )

    # KEEP-ALLOW — the DOCUMENTED fail-open (OUT-list item 4). An UNBALANCED
    # arithmetic region has no knowable end, so the mask skips that region
    # rather than guessing: the phantom heredoc still opens and the following
    # line stays masked. Deliberate, matching the hook's existing fail-open
    # doctrine for unresolvable state; pinned so it cannot drift silently.
    def test_issue1194_allow_unbalanced_arith_fails_open(self):
        self._cd_allow("echo $((a << b\ntrue; cd " + UP7)

    # --- Task 3: POSIX `--` end-of-options, shape 3b ----------------------
    # REMOVAL-ONLY. `_NESTED_SHELL_RE`'s flag group becomes
    # `(?:\s+-{1,2}[A-Za-z][A-Za-z-]*)*?` — a flag must start with a LETTER
    # after its dashes — so a bare `--` no longer satisfies it.

    # RED today (exit 2): after `--`, bash reads `-c` as a script FILENAME, so
    # no `cd` runs and the quoted string is an ordinary argument.
    def test_issue1194_allow_bash_double_dash_end_of_options(self):
        self._cd_allow('bash -- -c "cd ' + UP7 + '"')

    # RED today: the same with `sh`.
    def test_issue1194_allow_sh_double_dash_end_of_options(self):
        self._cd_allow('sh -- -c "cd ' + UP7 + '"')

    # --- Task 3 KEEP-BLOCK pins ------------------------------------------
    # Green at HEAD AND post-fix — the tightening must not widen into a miss.

    # A LONG flag still starts with a letter after its dashes.
    def test_issue1194_keepblock_bash_posix_long_flag_c(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'bash --posix -c "cd ' + UP7 + '"'},
            project_dir=self.P1188,
        )

    # GLUED flag letters are unaffected by the flag-group change.
    def test_issue1194_keepblock_bash_lc_glued_flag(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'bash -lc "cd ' + UP7 + '"'},
            project_dir=self.P1188,
        )

    # The next four are the shape-3a trade-off, pinned. A command-position
    # anchor on `_NESTED_SHELL_RE` would drop these from 2 to 0 — the measured
    # cost of "fixing" the unquoted-prose over-block, and why that stays
    # DOCUMENTED instead.
    def test_issue1194_keepblock_xargs_bash_c(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'xargs bash -c "cd ' + UP7 + '"'},
            project_dir=self.P1188,
        )

    def test_issue1194_keepblock_find_exec_bash_c(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'find . -exec bash -c "cd ' + UP7 + '" \\;'},
            project_dir=self.P1188,
        )

    def test_issue1194_keepblock_ssh_host_bash_c(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'ssh host bash -c "cd ' + UP7 + '"'},
            project_dir=self.P1188,
        )

    # The documented OVER-block itself (OUT-list item 6): UNQUOTED prose that
    # names the nested-shell shape blocks. Pinned as a BLOCK so the decision to
    # document rather than anchor is executable, not implied. Contrast the
    # #1192 pins above, where QUOTED prose in a commit message stays allowed.
    def test_issue1194_keepblock_echo_bash_c_documented_overblock(self):
        self.assertBlockedWith(
            CD_BLOCK_MSG, "Bash",
            {"command": 'echo bash -c "cd ' + UP7 + '"'},
            project_dir=self.P1188,
        )


if __name__ == "__main__":
    unittest.main()
