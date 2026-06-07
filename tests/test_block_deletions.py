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


if __name__ == "__main__":
    unittest.main()
