#!/bin/bash
set -uo pipefail

# Contract test for the fullsend post-dispatch completion-verification sub-step
# (issue #912). After the inline foreground execute `Agent` batch returns, the
# orchestrator MUST run scripts/verify-execute-completion.sh for every dispatched
# PATH A/B/D issue and act on the emitted `ACTION=` token instead of trusting the
# agent's narrated self-report (the #764/#814 directives are necessary but not
# sufficient — #838/#904 recurred). This test region-scopes fullsend's Step 6
# and asserts the new sub-step + helper invocation + recover wiring are present.
#
# Region matcher (the prior eval's fix 3): the region START anchors on the
# `6. **Execute (wave N)**` marker and the END on the `6b. CI-fix loop` marker.
# fullsend's `6b. CI-fix loop` is NON-bold (unlike execute-issue-plan's `**6b.`),
# so the END matcher tolerates BOTH forms: `^[[:space:]]*(\*\*)?6b\.`.
#
# ROOT/assert/PASS-FAIL-counter/`exit 1` shape mirrors
# tests/test-execute-skill-testwait-synchronous.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="skills/fullsend/SKILL.md"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$ROOT/$SKILL" ]; then
  echo "FAIL: $SKILL not found under $ROOT" >&2
  exit 1
fi

# Extract Step 6: from the `6. **Execute (wave N)**` marker up to (but not
# including) the `6b.` marker. END tolerates bold and non-bold via `(\*\*)?6b\.`.
REGION="$(awk '
  /^[[:space:]]*6\. \*\*Execute \(wave N\)\*\*/ {capturing=1}
  /^[[:space:]]*(\*\*)?6b\./ {capturing=0}
  capturing {print}
' "$ROOT/$SKILL")"

if [ -z "$REGION" ]; then
  echo "FAIL: could not extract Step 6 region from $SKILL (markers '6. **Execute (wave N)**' / '6b.' moved?)" >&2
  exit 1
fi

assert_region_contains() {
  local label="$1" needle="$2"
  inc
  if printf '%s' "$REGION" | grep -F -q -- "$needle"; then
    pass_msg "$label: Step 6 region contains \"$needle\""
  else
    fail_msg "$label: Step 6 region missing \"$needle\""
  fi
}

# 1) The helper is invoked by name in the Step 6 region.
assert_region_contains "helper-name" "verify-execute-completion.sh"

# 2) The orchestrator parses the emitted ACTION= token.
assert_region_contains "action-parse" "ACTION="

# 3) All four recover tokens are wired into the action table.
assert_region_contains "recover-push"       "recover-push"
assert_region_contains "recover-pr"         "recover-pr"
assert_region_contains "recover-label"      "recover-label"
assert_region_contains "recover-redispatch" "recover-redispatch"

# 4) A negation/MUST directive that the orchestrator does NOT trust the agent's
#    narrated self-report.
inc
if printf '%s' "$REGION" | grep -E -q -- 'self-report' \
   && printf '%s' "$REGION" | grep -E -q -- 'MUST|do NOT|never|NEVER|not trust'; then
  pass_msg "no-trust-directive: Step 6 region states orchestrator MUST/never-trust the agent self-report"
else
  fail_msg "no-trust-directive: Step 6 region missing a no-trust self-report directive"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
