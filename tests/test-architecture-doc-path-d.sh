#!/bin/bash
set -euo pipefail
# Guard: docs/architecture.md must document PATH D (quick-fix inline TDD path)
# with BARE tdd-implementer subagent and A > D > C > B routing precedence.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO_ROOT/docs/architecture.md"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

assert_contains() {
  local needle="$1"; local label="$2"
  inc
  if grep -qF -- "$needle" "$DOC"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

assert_not_contains() {
  local needle="$1"; local label="$2"
  inc
  if grep -qF -- "$needle" "$DOC"; then
    fail_msg "$label (unexpected substring present: $needle)"
  else
    pass_msg "$label"
  fi
}

echo "Architecture doc PATH D documentation"

assert_contains "PATH D" "mentions PATH D"
assert_contains "tdd-implementer" "names tdd-implementer subagent"
assert_contains "quick-fix" "describes quick-fix scope"
assert_contains "skips Step 8" "documents skipping Step 8 of execute-issue-plan"
assert_contains "skips evaluate-issue-plan" "documents skipping evaluate-issue-plan stage"
assert_contains "A > D > C > B" "documents routing precedence A > D > C > B"

# BARE subagent name only — no namespaced pipeline:tdd-implementer
assert_not_contains "pipeline:tdd-implementer" "uses BARE tdd-implementer (no pipeline: prefix)"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
