#!/bin/bash
# Discoverable wrapper (issue #965) — the repo test runner globs tests/test*.sh,
# so this shim runs the python unittest TestCase for hooks/block_deletions.py
# and (issue #1321) the shared hooks/command_mask.py helper it consumes.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 -m unittest -v tests/test_block_deletions.py tests/test_command_mask.py
