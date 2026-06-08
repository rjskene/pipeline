"""Direct-import unittest for hooks/_tool_input.py (issue #980, Leg 1 of the
Codex dual-target migration).

_tool_input_paths(event) -> list[str] is the SINGLE shared helper that both
restrict_paths.py and enforce-path-c-delegation.py will call (Leg 2) to obtain
the target file path(s) of an edit, covering BOTH harnesses:
  - Claude Code: Edit / Write -> [tool_input.file_path]
  - Codex CLI:   apply_patch  -> the file(s) named in the V4A patch envelope
                                 (*** Add/Update/Delete File:, *** Move to:)

It MUST be pure and fail-soft: every malformed / unknown / empty / None input
returns [] and the function never raises (Leg-2 consumer hooks must not crash on
an unexpected payload — the exact apply_patch tool_input shape is a known-unknown,
spec #4, so the parser probes plausible keys defensively)."""
import importlib.util
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
_MOD_PATH = REPO_ROOT / "hooks" / "_tool_input.py"

# Import the module directly by file path (hooks/ is not a package).
_spec = importlib.util.spec_from_file_location("_tool_input", _MOD_PATH)
_tool_input = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_tool_input)
_tool_input_paths = _tool_input._tool_input_paths


# --- sample Codex apply_patch V4A patch bodies ---
PATCH_ADD = """*** Begin Patch
*** Add File: src/new_module.py
+def hello():
+    return "hi"
*** End Patch"""

PATCH_UPDATE = """*** Begin Patch
*** Update File: src/existing.py
@@
-old line
+new line
*** End Patch"""

PATCH_DELETE = """*** Begin Patch
*** Delete File: src/gone.py
*** End Patch"""

PATCH_RENAME = """*** Begin Patch
*** Update File: src/old_name.py
*** Move to: src/new_name.py
@@
-x
+y
*** End Patch"""

PATCH_MULTI = """*** Begin Patch
*** Add File: a/first.py
+1
*** Update File: b/second.py
@@
-2
+2b
*** Delete File: c/third.py
*** End Patch"""


class TestToolInputPaths(unittest.TestCase):
    # ---------- Claude Code: Edit / Write ----------
    def test_cc_edit_returns_file_path(self):
        ev = {"tool_name": "Edit", "tool_input": {"file_path": "/repo/foo.py"}}
        self.assertEqual(_tool_input_paths(ev), ["/repo/foo.py"])

    def test_cc_write_returns_file_path(self):
        ev = {"tool_name": "Write", "tool_input": {"file_path": "/repo/bar.txt"}}
        self.assertEqual(_tool_input_paths(ev), ["/repo/bar.txt"])

    def test_cc_edit_missing_file_path_returns_empty(self):
        ev = {"tool_name": "Edit", "tool_input": {}}
        self.assertEqual(_tool_input_paths(ev), [])

    def test_cc_edit_empty_file_path_returns_empty(self):
        ev = {"tool_name": "Edit", "tool_input": {"file_path": ""}}
        self.assertEqual(_tool_input_paths(ev), [])

    # ---------- Codex apply_patch: single-op ----------
    def test_codex_add_file(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"input": PATCH_ADD}}
        self.assertEqual(_tool_input_paths(ev), ["src/new_module.py"])

    def test_codex_update_file(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"input": PATCH_UPDATE}}
        self.assertEqual(_tool_input_paths(ev), ["src/existing.py"])

    def test_codex_delete_file(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"input": PATCH_DELETE}}
        self.assertEqual(_tool_input_paths(ev), ["src/gone.py"])

    # ---------- Codex apply_patch: rename returns BOTH endpoints in order ----------
    def test_codex_rename_returns_both_endpoints_in_order(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"input": PATCH_RENAME}}
        # source (Update File) first, then destination (Move to) — a path
        # restriction must vet the destination as well as the source.
        self.assertEqual(
            _tool_input_paths(ev), ["src/old_name.py", "src/new_name.py"]
        )

    # ---------- Codex apply_patch: multi-file in document order ----------
    def test_codex_multi_file_document_order(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"input": PATCH_MULTI}}
        self.assertEqual(
            _tool_input_paths(ev),
            ["a/first.py", "b/second.py", "c/third.py"],
        )

    # ---------- Codex apply_patch: patch text under alternate keys ----------
    def test_codex_patch_under_patch_key(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"patch": PATCH_ADD}}
        self.assertEqual(_tool_input_paths(ev), ["src/new_module.py"])

    def test_codex_patch_under_content_key(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"content": PATCH_ADD}}
        self.assertEqual(_tool_input_paths(ev), ["src/new_module.py"])

    def test_codex_patch_as_raw_string_tool_input(self):
        # tool_input itself is the raw patch string (not a dict).
        ev = {"tool_name": "apply_patch", "tool_input": PATCH_ADD}
        self.assertEqual(_tool_input_paths(ev), ["src/new_module.py"])

    # ---------- fail-soft edges: always [] , never raise ----------
    def test_unknown_tool_returns_empty(self):
        ev = {"tool_name": "Bash", "tool_input": {"command": "ls"}}
        self.assertEqual(_tool_input_paths(ev), [])

    def test_empty_event_returns_empty(self):
        self.assertEqual(_tool_input_paths({}), [])

    def test_none_event_returns_empty(self):
        self.assertEqual(_tool_input_paths(None), [])

    def test_non_dict_event_returns_empty(self):
        self.assertEqual(_tool_input_paths("garbage"), [])
        self.assertEqual(_tool_input_paths(42), [])
        self.assertEqual(_tool_input_paths([1, 2, 3]), [])

    def test_apply_patch_no_patch_text_returns_empty(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"unrelated": "x"}}
        self.assertEqual(_tool_input_paths(ev), [])

    def test_apply_patch_garbage_patch_returns_empty(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"input": "not a patch"}}
        self.assertEqual(_tool_input_paths(ev), [])

    def test_apply_patch_empty_string_returns_empty(self):
        ev = {"tool_name": "apply_patch", "tool_input": {"input": ""}}
        self.assertEqual(_tool_input_paths(ev), [])

    def test_tool_input_non_dict_non_str_returns_empty(self):
        # tool_input is an int / list -> no path extractable, fail soft.
        ev = {"tool_name": "apply_patch", "tool_input": 123}
        self.assertEqual(_tool_input_paths(ev), [])
        ev = {"tool_name": "Edit", "tool_input": [1, 2]}
        self.assertEqual(_tool_input_paths(ev), [])

    def test_missing_tool_name_returns_empty(self):
        ev = {"tool_input": {"file_path": "/repo/foo.py"}}
        self.assertEqual(_tool_input_paths(ev), [])


if __name__ == "__main__":
    unittest.main()
