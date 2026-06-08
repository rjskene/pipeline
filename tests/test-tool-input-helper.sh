#!/bin/bash
set -uo pipefail

# Discoverable bash wrapper (matches the tests/test*.sh glob in PIPELINE_TEST_CMD)
# that runs the Python unittest for hooks/_tool_input.py (issue #980, Leg 1 of the
# Codex dual-target migration). Mirrors the sibling wrapper convention used for
# hooks/block_deletions.py (tests/test_block_deletions.py).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available — skipping _tool_input unittest"
  exit 0
fi

# Run the unittest module directly (it calls unittest.main() under __main__);
# `-v` is forwarded to unittest's argv for verbose PASS/FAIL-per-test output.
python3 "$SCRIPT_DIR/test_tool_input.py" -v 2>&1
