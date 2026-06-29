#!/bin/bash
# Discoverable wrapper (issue #1136) — the repo test runner globs tests/test*.sh,
# so this shim runs the python unittest TestCase for hooks/restrict_paths.py.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 -m unittest -v tests/test_restrict_paths.py
