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

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._proj_tmp, ignore_errors=True)
        shutil.rmtree(cls._out_tmp, ignore_errors=True)
        shutil.rmtree(cls._midword_tmp, ignore_errors=True)

    # --- subprocess driver -------------------------------------------------
    def run_hook(self, tool_name, tool_input, *, cwd=None, project_dir=None):
        """Invoke the real hook; return its exit code.

        The hook resolves the project boundary from CLAUDE_PROJECT_DIR and
        resolves relative paths against the process CWD (the bug). We control
        both so the Bug-1 cases can put CWD outside the project.
        """
        proj = project_dir or self.PROJECT
        env = dict(os.environ)
        env["CLAUDE_PROJECT_DIR"] = proj
        payload = json.dumps({"tool_name": tool_name, "tool_input": tool_input})
        proc = subprocess.run(
            [sys.executable, str(HOOK)],
            input=payload, capture_output=True, text=True, env=env,
            cwd=cwd or proj,
        )
        return proc.returncode, proc.stderr

    def assertAllowed(self, tool_name, tool_input, *, cwd=None, project_dir=None):
        rc, err = self.run_hook(tool_name, tool_input, cwd=cwd, project_dir=project_dir)
        self.assertEqual(
            rc, ALLOW,
            f"expected ALLOW (exit 0) for {tool_name} {tool_input!r}; got {rc}; stderr={err!r}",
        )

    def assertBlocked(self, tool_name, tool_input, *, cwd=None, project_dir=None):
        rc, err = self.run_hook(tool_name, tool_input, cwd=cwd, project_dir=project_dir)
        self.assertEqual(
            rc, BLOCK,
            f"expected BLOCK (exit 2) for {tool_name} {tool_input!r}; got {rc}; stderr={err!r}",
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


if __name__ == "__main__":
    unittest.main()
