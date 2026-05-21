#!/bin/bash
# Tests for skills/run/SKILL.md step 4 — the grouped status renderer
# introduced by issue #133. The test validates the rendering contract by
# asserting structural anchors in the prose (the renderer is executed by
# the orchestrator, not by a script).
#
# After issue #340, the rendered ASCII example blocks moved out of
# SKILL.md into skills/run/references/status-table-layout.md. SKILL.md
# still owns the decision/operational rules (NOTES-default rule, scope
# bucketing rule, counts footer rule); the ASCII renders live in the
# reference file. This test asserts the structural anchors in whichever
# file currently owns them.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/run/SKILL.md"
REF="${ROOT}/skills/run/references/status-table-layout.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 (pattern: $2)"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

want_present_in() {
  local file="$1" name="$2" pat="$3"
  inc
  if grep -qE -- "$pat" "$file"; then
    pass_msg "$name"
  else
    fail_msg "$name [in $(basename "$file")]" "$pat"
  fi
}

want_absent_in() {
  local file="$1" name="$2" pat="$3"
  inc
  if grep -qE -- "$pat" "$file"; then
    fail_msg "$name [in $(basename "$file")] (unexpected pattern present)" "$pat"
  else
    pass_msg "$name"
  fi
}

# 1. EPICS section header in ASCII example — moved to references/.
want_present_in "$REF" "1. EPICS section header in example" '^[[:space:]]*EPICS[[:space:]]*$'

# 2. ORPHANS section header in ASCII example — moved to references/.
want_present_in "$REF" "2. ORPHANS section header in example" '^[[:space:]]*ORPHANS[[:space:]]*$'

# 3. At least one indented child row (leading spaces before #) — moved to references/.
want_present_in "$REF" "3. Indented child row example" '^[[:space:]]{6,}#[0-9]+'

# 4. Scope bucket label `(none / generic)` — moved to references/.
want_present_in "$REF" "4. (none / generic) scope bucket" '\(none / generic\)'

# 5. Counts footer pattern: N epics + N children + N orphans = N open — moved to references/.
want_present_in "$REF" "5. Counts footer pattern" '[0-9]+ epics \+ [0-9]+ children \+ [0-9]+ orphans = [0-9]+ open'

# 6. Footer NOTES table with columns Target Base, Path, Blocked by.
#    The rendered example moved to references/; the inline decision rule
#    (which surfaces only non-default values) stays in SKILL.md.
want_present_in "$REF"   "6a. NOTES footer header"           '^[[:space:]]*NOTES \(non-default\)'
want_present_in "$REF"   "6b. Notes column: Target Base"     'Target Base'
want_present_in "$REF"   "6c. Notes column: Path"            '\| *Path *\||  Path  |Path  |Path\b'
want_present_in "$REF"   "6d. Notes column: Blocked by"      'Blocked by'
# SKILL.md still describes the NOTES-default rule even though the rendered example moved.
want_present_in "$SKILL" "6e. SKILL.md retains NOTES rule"   'NOTES footer \(non-default'

# 7. Legacy per-row column header must be GONE from the main grouped table.
#    The exact legacy header signature from pre-#133 SKILL.md must not
#    reappear in either the SKILL.md or the new reference file.
want_absent_in "$SKILL" "7a. Legacy header signature absent in SKILL.md" 'Issue +Title +Stage +Tags +Target Base +Path +Blocked\?'
want_absent_in "$REF"   "7b. Legacy header signature absent in references/" 'Issue +Title +Stage +Tags +Target Base +Path +Blocked\?'

# 8. SKILL.md still links to the moved example file.
want_present_in "$SKILL" "8. SKILL.md links to references/status-table-layout.md" 'references/status-table-layout\.md'

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
