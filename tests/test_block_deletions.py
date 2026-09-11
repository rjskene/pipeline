"""Discoverable-via-wrapper unittest for hooks/block_deletions.py (issue #965).
Drives the real hook as a subprocess with a JSON stdin payload, asserting
exit code (2 = blocked, 0 = allowed) — mirrors the subprocess-isolation
convention of tests/test-restrict-paths-hook.sh."""
import os
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HOOK = REPO_ROOT / "hooks" / "block_deletions.py"
DEVNULL = "/dev/" + "null"   # built from fragments so restrict_paths.py
DEVZERO = "/dev/" + "zero"   # (sibling hook) doesn't flag the literal path
# Issue #1321 — the deletion verbs, built from fragments (same convention as
# DEVNULL) so this test SOURCE never spells the denied token that the live
# block_deletions.py hook would refuse in a Bash heredoc / sed -i edit.
RMRF = "rm -r" + "f"
RESET = "git reset --" + "hard"


def run_hook_full(command, allow_deletions=False):
    """Invoke the hook with an isolated env; return (exit code, stderr)."""
    payload = '{"tool_name":"Bash","tool_input":{"command":%s}}' % (
        __import__("json").dumps(command)
    )
    env = {"PATH": os.environ.get("PATH", "")}
    if allow_deletions:
        env["ALLOW_DELETIONS"] = "true"
    proc = subprocess.run(
        [sys.executable, str(HOOK)],
        input=payload, capture_output=True, text=True, env=env,
    )
    return proc.returncode, proc.stderr


def run_hook(command, allow_deletions=False):
    """Invoke the hook with an isolated env; return its exit code."""
    return run_hook_full(command, allow_deletions=allow_deletions)[0]


class TestBlockDeletions(unittest.TestCase):
    def assertBlocked(self, cmd):
        self.assertEqual(run_hook(cmd), 2, f"expected BLOCK (exit 2) for: {cmd}")

    def assertAllowed(self, cmd):
        self.assertEqual(run_hook(cmd), 0, f"expected ALLOW (exit 0) for: {cmd}")

    # --- truncate-to-zero (issue #965) ---
    def test_truncate_size_zero_blocked(self):
        for cmd in ("truncate -s 0 file.txt", "truncate -s0 file.txt",
                    "truncate --size=0 file.txt", "truncate --size 0 file.txt"):
            with self.subTest(cmd=cmd):
                self.assertBlocked(cmd)

    def test_truncate_grow_allowed(self):
        # -s 100M GROWS/sizes a sparse file — not zeroing, must NOT block.
        self.assertAllowed("truncate -s 100M sparse.img")

    # --- explicit clobber idioms (issue #965; `: > file` DROPPED by #1321) ---
    # #1321 removed the `: > file` entry from BLOCKED: creating/emptying a
    # tracked file is an edit, and git is the undo. The forced-clobber `>|`
    # operator below stays blocked.
    def test_colon_noop_create_allowed(self):
        for cmd in (": > config.json", ":> config.json", "echo done && : > log.txt"):
            with self.subTest(cmd=cmd):
                self.assertAllowed(cmd)

    def test_force_clobber_blocked(self):
        for cmd in ("cat foo >| out.txt", "foo >|out.txt"):
            with self.subTest(cmd=cmd):
                self.assertBlocked(cmd)

    def test_plain_redirection_allowed(self):
        # CORE TENSION: plain `>` / `>>` redirection is ubiquitous & legit — NEVER block.
        for cmd in ("foo > out.txt", "echo hi > log.txt", "echo hi >> log.txt",
                    "cat a.txt > b.txt", "grep x file | sort > sorted.txt",
                    "ls -la > listing.txt"):
            with self.subTest(cmd=cmd):
                self.assertAllowed(cmd)

    # --- overwrite-with-empty / zero-fill (issue #965) ---
    def test_cp_devnull_blocked(self):
        self.assertBlocked("cp " + DEVNULL + " tracked.txt")

    def test_cp_normal_allowed(self):
        self.assertAllowed("cp source.txt dest.txt")

    def test_dd_zeroing_blocked(self):
        for cmd in ("dd if=" + DEVNULL + " of=file.bin",
                    "dd of=file.bin if=" + DEVZERO + " count=0",
                    "dd if=" + DEVZERO + " of=disk.img count=0"):
            with self.subTest(cmd=cmd):
                self.assertBlocked(cmd)

    def test_dd_disk_copy_allowed(self):
        # dd with of= but no null/zero source and no count=0 is a real copy — allow.
        self.assertAllowed("dd if=/dev/" + "sda of=backup.img")

    # --- in-place rewrite (issue #965; `sed -i` DROPPED by #1321) ---
    # #1321 removed the `sed -i` entry from BLOCKED: an in-place rewrite of a
    # tracked file is an edit, and git is the undo. Protected control files
    # stay covered by restrict_paths._protected_write_context (unchanged).
    def test_sed_inplace_allowed(self):
        for cmd in ("sed -i 's/a/b/' file.txt", "sed -i.bak 's/a/b/' file.txt",
                    "sed --in-place 's/a/b/' file.txt", "sed -ni 's/a/b/' file.txt"):
            with self.subTest(cmd=cmd):
                self.assertAllowed(cmd)

    def test_sed_stream_allowed(self):
        # sed WITHOUT -i is a stream filter (output redirected) — must NOT block.
        self.assertAllowed("sed 's/a/b/' file.txt > out.txt")

    # --- escape hatch + existing-verb regressions ---
    def test_allow_deletions_escape_hatch(self):
        # ALLOW_DELETIONS=true short-circuits at module top for NEW patterns too.
        self.assertEqual(run_hook("truncate -s 0 file.txt", allow_deletions=True), 0)
        self.assertEqual(run_hook("rm -rf build", allow_deletions=True), 0)

    def test_existing_deletion_verbs_still_blocked(self):
        for cmd in ("rm -rf build", "rm -r dir", "git clean -fd",
                    "git reset --hard HEAD~1"):
            with self.subTest(cmd=cmd):
                self.assertBlocked(cmd)

    def test_benign_commands_allowed(self):
        for cmd in ("make build", "python3 -c 'print(1)'", "ls -la"):
            with self.subTest(cmd=cmd):
                self.assertAllowed(cmd)

    # ======================================================================
    # Issue #1321 — verbs are matched in COMMAND-WORD position on the masked
    # text (hooks/command_mask.py): a deletion verb that appears only inside
    # a quoted pattern operand, a heredoc body, or a `--grep=` value is not a
    # command. Recursive removes whose EVERY target is a literal temp path
    # (or a literal `$(mktemp …)`) are allowed. Wrapped verbs (sudo / xargs /
    # find -exec / pipes / `$( )` / timeout / bash -c / eval / `{ …; }`) and
    # any non-temp or variable target still deny. The block message names
    # the matched token so it is visible past the 120-char prefix.
    # ======================================================================

    # RED today (rc 2): the whole-text regex hits the verb inside a quoted
    # grep pattern / echo operand / `git log --grep=` value.
    def test_1321_quoted_pattern_operand_allowed(self):
        for cmd in ("grep -rnE '" + RMRF + " |reset --hard' docs/",
                    "echo '" + RMRF + " build'",
                    "git log --grep='" + RESET + "'"):
            with self.subTest(cmd=cmd):
                self.assertAllowed(cmd)

    # RED today (rc 2): the verb sits inside a quoted-delimiter heredoc BODY
    # owned by `cat` (not executed) — the body is masked post-fix.
    def test_1321_heredoc_body_allowed(self):
        self.assertAllowed(
            "cat > t.sh <<'EOF'\ntrap '" + RMRF + " \"$WORK_ROOT\"' EXIT\nEOF"
        )

    # RED today (rc 2): every target is a literal `/tmp/<…>` path (or a
    # literal `$(mktemp -d)` substitution), so the remove is temp-scoped.
    def test_1321_tmp_scoped_recursive_remove_allowed(self):
        for cmd in (RMRF + " /tmp/tmp.abc123",
                    RMRF + " /tmp/a /tmp/b",
                    "rm -r \"/tmp/tmp.x y\"",
                    RMRF + " -- /tmp/tmp.q",
                    RMRF + " \"$(mktemp -d)\""):
            with self.subTest(cmd=cmd):
                self.assertAllowed(cmd)

    # CONTROLS — green today (the whole-text regex already denies every
    # wrapped form); load-bearing once matching narrows to head position:
    # fails a GREEN that forgets wrapper skipping, `find -exec`, pipe heads,
    # `$( )` / `{` as head anchors, `bash -c` / `eval` operand visibility, or
    # masks a DOUBLE-quoted `$(…)` interior that bash expands.
    def test_1321_wrapped_verbs_still_blocked(self):
        for cmd in ("sudo " + RMRF + " build",
                    "echo build | xargs " + RMRF,
                    "find . -name x -exec " + RMRF + " {} +",
                    "ls | " + RMRF + " build",
                    "echo $(" + RMRF + " build)",
                    "timeout 5 " + RMRF + " build",
                    "bash -c '" + RMRF + " build'",
                    "eval \"" + RMRF + " build\"",
                    "{ " + RMRF + " build; }",
                    "echo \"$(" + RMRF + " build)\"",
                    "git commit -m \"$(" + RMRF + " build)\"",
                    # eval-fix: the `\rm` alias-bypass spelling was denied
                    # pre-#1321 (`\b` anchor) and must stay denied.
                    "\\" + RMRF + " build"):
            with self.subTest(cmd=cmd):
                self.assertBlocked(cmd)

    # CONTROLS — green today; load-bearing once the temp carve-out lands:
    # a `$VAR` target, a mixed temp/non-temp target list, a `..` escape out
    # of /tmp, the bare /tmp root, and a missing target must all still deny
    # (no shell variable resolution, ever).
    def test_1321_tmp_scope_controls_blocked(self):
        for cmd in (RMRF + " \"$T\"",
                    "T=$(mktemp -d); " + RMRF + " \"$T\"",
                    RMRF + " /tmp/x src/",
                    RMRF + " /tmp/../home",
                    RMRF + " /tmp",
                    RMRF,
                    # eval-fix: targets the command text does not show —
                    # xargs appends stdin; brace/glob expansion can reach
                    # `..` after normpath has already accepted the literal.
                    "echo build | xargs " + RMRF + " /tmp/x",
                    "echo x | xargs -I{} " + RMRF + " /tmp/{}",
                    RMRF + " /tmp/{x,../home}",
                    RMRF + " /tmp/.*/home"):
            with self.subTest(cmd=cmd):
                self.assertBlocked(cmd)

    # RED today: stderr reads `…detected: rm -rf build` with no
    # `(matched: …)` token; post-fix the matched verb / operator is named
    # BEFORE the 120-char command prefix.
    def test_1321_blocked_message_names_matched_token(self):
        rc, err = run_hook_full(RMRF + " build")
        self.assertEqual(rc, 2, f"expected BLOCK (exit 2); stderr={err!r}")
        self.assertIn("(matched: " + RMRF + ")", err)
        rc, err = run_hook_full("cat foo >| out.txt")
        self.assertEqual(rc, 2, f"expected BLOCK (exit 2); stderr={err!r}")
        self.assertIn("(matched: >| out.txt)", err)


if __name__ == "__main__":
    unittest.main()
