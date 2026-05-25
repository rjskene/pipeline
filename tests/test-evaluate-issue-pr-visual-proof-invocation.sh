#!/bin/bash
set -euo pipefail
# Guard: evaluate-issue-pr Step 6 must invoke pipeline:visual-proof-from-plan as
# the verdict layer for needs-browser issues, flag on any unsatisfied entry, and
# surface a Visual proof row in the Step 9 evaluation comment template.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE="$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"
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

echo "evaluate-issue-pr visual-proof verdict invocation"

# (a) needs-browser gating phrase
assert_contains "If the issue carries the needs-browser label" "needs-browser gating phrase present"

# (b) references the visual-proof-from-plan sub-skill
assert_contains "pipeline:visual-proof-from-plan" "references pipeline:visual-proof-from-plan"

# (c) Flagged-on-unsatisfied prose
assert_contains "the verdict MUST be Flagged" "Flagged-on-unsatisfied verdict prose present"
assert_contains "unsatisfied" "references unsatisfied predicates"

# (d) Visual proof row in the Step 9 evaluation comment template
assert_contains "**Visual proof:**" "Visual proof row in eval comment template"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
