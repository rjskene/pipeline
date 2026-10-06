#!/bin/bash
set -euo pipefail
# Guard: execute-issue-plan SKILL.md wires in the visual-proof-from-plan
# sub-skill as a per-section TDD loop, gated behind the needs-browser label.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# #1444: Steps 6c/6d were relocated out of the hot-path SKILL.md into
# references/visual-validation.md (the skill keeps the step headings + a read
# pointer). The contract text follows the text to its new file; SKILL.md is
# asserted separately to still carry the pointer, so the relocation cannot
# silently become a deletion.
SKILL="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"
FILE="$REPO_ROOT/skills/execute-issue-plan/references/visual-validation.md"
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

# (0) the relocation target exists and SKILL.md Steps 6c/6d point at it.
inc
if [ -f "$FILE" ]; then
  pass_msg "references/visual-validation.md exists"
else
  fail_msg "references/visual-validation.md missing (6c/6d relocation target)"
fi
inc
if grep -qF -- "references/visual-validation.md" "$SKILL" && grep -qF -- "**6c." "$SKILL"; then
  pass_msg "SKILL.md keeps the 6c/6d step heading and the read pointer"
else
  fail_msg "SKILL.md must keep the **6c. heading and a references/visual-validation.md pointer"
fi

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
