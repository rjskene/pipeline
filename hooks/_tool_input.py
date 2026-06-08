"""Shared tool-input path extraction for the enforcement hooks (issue #980, Leg 1
of the Codex dual-target migration).

`_tool_input_paths(event) -> list[str]` returns the target file path(s) of an
edit operation across BOTH harnesses, so restrict_paths.py and
enforce-path-c-delegation.py (Leg 2 consumers) share one path-extraction code
path instead of each branching on tool name:

  - Claude Code: tool_name `Edit` / `Write` -> [tool_input["file_path"]]
  - Codex CLI:   tool_name `apply_patch`    -> every file named in the V4A patch
                 envelope, in document order:
                     *** Add File: <path>
                     *** Update File: <path>
                     *** Delete File: <path>
                     *** Move to: <path>          (rename destination)
                 A rename emits both `*** Update File:` (source) and
                 `*** Move to:` (destination), so the source AND destination are
                 both returned, in that order — a path-restriction consumer must
                 vet the destination as well as the source.

Contract: PURE and FAIL-SOFT. Any malformed / unknown / empty / None input
returns [] and the function never raises. The exact `apply_patch` tool_input
shape is a known-unknown (spec #4): the parser probes the plausible string keys
(`input`, `patch`, `content`) and a raw-string `tool_input`, and degrades to []
rather than crashing the Leg-2 consumer hooks on an unexpected payload."""
import re

# Matches any V4A patch file header (Add/Update/Delete File + Move-to rename
# destination) and captures the path. Non-greedy + trailing-\s strip so an
# accidental trailing space does not leak into the path.
_PATCH_HEADER_RE = re.compile(
    r"^\*\*\*\s+(?:Add File|Update File|Delete File|Move to):\s*(.+?)\s*$",
    re.MULTILINE,
)

# Ordered keys probed for the patch text when tool_input is a dict. `input` is
# the documented Codex apply_patch field; `patch`/`content` are defensive
# fallbacks (spec known-unknown #4).
_PATCH_TEXT_KEYS = ("input", "patch", "content")


def _patch_text(tool_input):
    """Best-effort extraction of the raw V4A patch string from a Codex
    apply_patch tool_input (a dict under one of _PATCH_TEXT_KEYS, or the raw
    string itself). Returns "" when no plausible text is present."""
    if isinstance(tool_input, str):
        return tool_input
    if isinstance(tool_input, dict):
        for key in _PATCH_TEXT_KEYS:
            val = tool_input.get(key)
            if isinstance(val, str) and val:
                return val
    return ""


def _tool_input_paths(event):
    """Return the list of target file paths for the edit described by `event`.

    Fail-soft: returns [] for any unrecognized / malformed / empty input and
    never raises."""
    try:
        if not isinstance(event, dict):
            return []
        tool_name = event.get("tool_name")
        if not tool_name:
            return []
        tool_input = event.get("tool_input")

        # --- Claude Code: Edit / Write ---
        if tool_name in ("Edit", "Write"):
            if isinstance(tool_input, dict):
                fp = tool_input.get("file_path")
                if isinstance(fp, str) and fp:
                    return [fp]
            return []

        # --- Codex CLI: apply_patch (Edit+Write collapse to this tool) ---
        if tool_name == "apply_patch":
            text = _patch_text(tool_input)
            if not text:
                return []
            return [m.group(1) for m in _PATCH_HEADER_RE.finditer(text)]

        # Unknown / non-edit tool.
        return []
    except Exception:
        # Absolute fail-soft guarantee — a path-extraction helper must never be
        # the reason an enforcement hook crashes.
        return []
