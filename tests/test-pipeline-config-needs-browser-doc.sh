#!/bin/bash
set -euo pipefail
# Guard: after issue #514 removed container isolation, pipeline.config.example
# must NOT document the deleted needs-browser executor-container routing
# (the #368 label gate in spawn-claude.sh that allowed execute-issue-plan
# under --container-mode is gone). The needs-browser label still exists, but
# it routes work via inline Agent dispatch — not through pipeline.config.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE="$REPO_ROOT/pipeline.config.example"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

assert_absent() {
  local needle="$1"; local label="$2"
  inc
  if grep -qF -- "$needle" "$FILE"; then
    fail_msg "$label (forbidden substring still present: $needle)"
  else
    pass_msg "$label"
  fi
}

echo "pipeline.config.example post-#514 container-doc removal"

# The needs-browser executor-container carve-out lived only inside the
# deleted container-mode skill-allowlist block. Both strings should be gone.
assert_absent "needs-browser" "needs-browser routing prose removed"
assert_absent "#368" "issue #368 reference removed"
assert_absent "--container-mode" "--container-mode flag references removed"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
