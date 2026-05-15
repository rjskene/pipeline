#!/bin/bash
# Tests for skills/run/SKILL.md step 4 — the grouped status renderer
# introduced by issue #133. The test validates the rendering contract by
# asserting structural anchors in the SKILL.md prose itself (the renderer
# is executed by the orchestrator, not by a script).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/run/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 (pattern: $2)"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

want_present() {
  local name="$1" pat="$2"
  inc
  if grep -qE -- "$pat" "$SKILL"; then
    pass_msg "$name"
  else
    fail_msg "$name" "$pat"
  fi
}

want_absent() {
  local name="$1" pat="$2"
  inc
  if grep -qE -- "$pat" "$SKILL"; then
    fail_msg "$name (unexpected pattern present)" "$pat"
  else
    pass_msg "$name"
  fi
}

# 1. EPICS section header in ASCII example.
want_present "1. EPICS section header in example" '^[[:space:]]*EPICS[[:space:]]*$'

# 2. ORPHANS section header in ASCII example.
want_present "2. ORPHANS section header in example" '^[[:space:]]*ORPHANS[[:space:]]*$'

# 3. At least one indented child row (leading spaces before #).
want_present "3. Indented child row example" '^[[:space:]]{6,}#[0-9]+'

# 4. Scope bucket label `(none / generic)`.
want_present "4. (none / generic) scope bucket" '\(none / generic\)'

# 5. Counts footer pattern: N epics + N children + N orphans = N open.
want_present "5. Counts footer pattern" '[0-9]+ epics \+ [0-9]+ children \+ [0-9]+ orphans = [0-9]+ open'

# 6. Footer NOTES table with columns Target Base, Path, Blocked by.
want_present "6a. NOTES footer header"   '^[[:space:]]*NOTES \(non-default\)'
want_present "6b. Notes column: Target Base" 'Target Base'
want_present "6c. Notes column: Path"        '\| *Path *\||  Path  |Path  |Path\b'
want_present "6d. Notes column: Blocked by"  'Blocked by'

# 7. Legacy per-row column header must be GONE from the main grouped table.
#    The exact legacy header signature from pre-#133 SKILL.md.
want_absent "7. Legacy header signature absent" 'Issue +Title +Stage +Tags +Target Base +Path +Blocked\?'

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
