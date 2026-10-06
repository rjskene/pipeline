#!/bin/bash
# Discoverable wrapper — the repo test runner globs tests/test*.sh and
# tests/test_*.sh, never tests/*.py, so this shim is what makes the python
# unittest TestCase for hooks/command_mask.py run in the suite. It replaces the
# entrypoint lost when tests/test-block-deletions-hook.sh was deleted with
# hooks/block_deletions.py (issue #1418) — that file was the ONLY runner that
# invoked tests/test_command_mask.py.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 -m unittest -v tests/test_command_mask.py
