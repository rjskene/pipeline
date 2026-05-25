#!/bin/bash
set -euo pipefail
# Guard: skills/plan-issue/SKILL.md must REQUIRE machine-checkable predicates
# for needs-browser-labeled issues (planner-side requirement for the
# visual-proof-from-plan sub-skill). Enforcement in post-plan.sh is OUT OF SCOPE.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE="$REPO_ROOT/skills/plan-issue/SKILL.md"
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

echo "plan-issue needs-browser predicate requirement"

# (a) step 3c context references the needs-browser label
assert_contains "needs-browser" "references needs-browser label"
# (b) the required section name appears
assert_contains "**Predicates:**" "names the Predicates section"
# (c) the mcp__playwright_*browser_evaluate reference appears
assert_contains "browser_evaluate" "references browser_evaluate"
# (d) an example predicate uses the querySelectorAll pattern (.length needs a NodeList)
assert_contains "querySelectorAll(" "includes a querySelectorAll example predicate"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
