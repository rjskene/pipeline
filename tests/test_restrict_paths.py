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


if __name__ == "__main__":
    unittest.main()
