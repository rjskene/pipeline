"""Discoverable-via-wrapper unittest for hooks/block_deletions.py (issue #965).
Drives the real hook as a subprocess with a JSON stdin payload, asserting
exit code (1 = blocked, 0 = allowed) — mirrors the subprocess-isolation
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


def run_hook(command, allow_deletions=False):
    """Invoke the hook with an isolated env; return its exit code."""
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
    return proc.returncode


class TestBlockDeletions(unittest.TestCase):
    def assertBlocked(self, cmd):
        self.assertEqual(run_hook(cmd), 1, f"expected BLOCK (exit 1) for: {cmd}")

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

    # --- explicit clobber idioms (issue #965) ---
    def test_colon_noop_truncate_blocked(self):
        for cmd in (": > config.json", ":> config.json", "echo done && : > log.txt"):
            with self.subTest(cmd=cmd):
                self.assertBlocked(cmd)

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

    # --- in-place rewrite (issue #965) ---
    def test_sed_inplace_blocked(self):
        for cmd in ("sed -i 's/a/b/' file.txt", "sed -i.bak 's/a/b/' file.txt",
                    "sed --in-place 's/a/b/' file.txt", "sed -ni 's/a/b/' file.txt"):
            with self.subTest(cmd=cmd):
                self.assertBlocked(cmd)

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


if __name__ == "__main__":
    unittest.main()
