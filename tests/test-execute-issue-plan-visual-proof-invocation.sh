#!/bin/bash
set -euo pipefail
# Guard: execute-issue-plan SKILL.md wires in the visual-proof-from-plan
# sub-skill as a per-section TDD loop, gated behind the needs-browser label.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

assert_contains() {
  local needle="$1"; local label="$2"
  inc
  if grep -qF -- "$needle" "$FILE"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

echo "execute-issue-plan visual-proof-from-plan invocation wiring"

# (a) needs-browser label appears within the per-section loop section
assert_contains "needs-browser" "references needs-browser label"

# (b) references the visual-proof-from-plan sub-skill
assert_contains "pipeline:visual-proof-from-plan" "invokes pipeline:visual-proof-from-plan sub-skill"

# (c) gated behind a conditional label check (not blanket)
assert_contains "If the issue carries the needs-browser label" "gates loop behind needs-browser conditional"

# (d) loop-exit condition
assert_contains "unsatisfied = []" "documents loop-exit condition unsatisfied = []"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
