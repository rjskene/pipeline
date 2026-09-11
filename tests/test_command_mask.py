"""Unit tests for hooks/command_mask.py (issue #1321) — the shared
heredoc-body + quoted-operand masking helper consumed by block_deletions.py
and enforce-comment-trust.py.

Exercises the helper API in-process (not via a hook subprocess):

  mask_command(text)  — length-preserving regex-friendly view: heredoc body
                        lines and quoted-string interiors become spaces,
                        EXCEPT operands of a shell-headed segment
                        (`bash -c '…'`, `eval …`) which execute and so stay
                        visible. An unterminated quote returns the text
                        unmasked (fail closed for the consumers).
  segments(text)      — structural view: list of (start_offset, [dequoted
                        words]) per shell segment; `-c`/`eval` bodies recurse
                        one level. `None` on an unterminated quote.
  head_index(words)   — index of the command word after skipping `NAME=`
                        assignments, reserved words and wrapper words
                        (sudo/env/timeout N/xargs …); -1 when none.

RED at the [split-role-red] commit with
`ModuleNotFoundError: No module named 'command_mask'` (the helper does not
exist yet); fully green at plan Task 2. Discoverable via
tests/test-block-deletions-hook.sh.
"""
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "hooks"))

from command_mask import mask_command, segments, head_index  # noqa: E402


class TestMaskCommand(unittest.TestCase):
    # (a) a quoted grep PATTERN operand: interior -> spaces, the quote
    #     delimiters and the overall length are preserved.
    def test_a_quoted_pattern_operand_masked_length_preserving(self):
        src = "grep -rnE 'rm -rf |x' docs/"
        out = mask_command(src)
        self.assertEqual(out, "grep -rnE '         ' docs/")
        self.assertEqual(len(out), len(src))

    # (b) a heredoc BODY line is masked to all spaces; the operator line keeps
    #     its delimiters (the quoted `'EOF'` interior IS masked because the
    #     `cat`-headed segment is not a shell word); the terminator line is
    #     emitted verbatim.
    def test_b_heredoc_body_masked_terminator_verbatim(self):
        src = "cat > t.sh <<'EOF'\ntrap 'rm -rf \"$W\"' EXIT\nEOF"
        lines = mask_command(src).split("\n")
        src_lines = src.split("\n")
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[0], "cat > t.sh <<'   '")
        self.assertEqual(lines[1], " " * len(src_lines[1]))
        self.assertEqual(lines[2], "EOF")

    # (c) a shell-headed segment keeps its quoted operands visible — they are
    #     executed, so a downstream regex must still see them.
    def test_c_shell_headed_segment_keeps_quoted_operands(self):
        src = "bash -c 'rm -rf x'"
        self.assertEqual(mask_command(src), src)

    # (d) an unterminated quote -> text returned unmasked (fail closed).
    def test_d_unterminated_quote_returns_input_unmasked(self):
        src = "echo 'rm -rf x"
        self.assertEqual(mask_command(src), src)


class TestSegments(unittest.TestCase):
    # (e) dequoted words per segment; `;` and `|` start new segments; empty
    #     segments are dropped; a quoted operand with a space is ONE word.
    def test_e_dequoted_words_per_segment(self):
        src = "A=1 sudo rm -rf \"/tmp/x y\" ; ls | wc -l"
        words = [w for _, w in segments(src)]
        self.assertEqual(
            words,
            [["A=1", "sudo", "rm", "-rf", "/tmp/x y"], ["ls"], ["wc", "-l"]],
        )

    # (f) depth-1 recursion into a `-c` body of a shell-headed segment.
    def test_f_bash_c_body_recursed_depth_one(self):
        src = "bash -c 'gh issue view 5 --json body'"
        segs = [w for _, w in segments(src)]
        self.assertIn(["gh", "issue", "view", "5", "--json", "body"], segs)

    # (h) unterminated quote -> None.
    def test_h_unterminated_quote_is_none(self):
        self.assertIsNone(segments("echo 'x"))


class TestHeadIndex(unittest.TestCase):
    # (g) the command word after assignments / reserved words / wrappers and
    #     their positional values; -1 when the segment has no command word.
    def test_g_head_index(self):
        self.assertEqual(head_index(["A=1", "sudo", "rm", "-rf"]), 2)
        self.assertEqual(head_index(["{", "rm"]), 1)
        self.assertEqual(head_index(["timeout", "5", "rm"]), 2)
        self.assertEqual(head_index(["xargs", "-I{}", "rm"]), 2)
        self.assertEqual(head_index([]), -1)


if __name__ == "__main__":
    unittest.main()
