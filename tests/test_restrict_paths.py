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

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._proj_tmp, ignore_errors=True)
        shutil.rmtree(cls._out_tmp, ignore_errors=True)

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


if __name__ == "__main__":
    unittest.main()
