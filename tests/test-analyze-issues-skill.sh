#!/bin/bash
# Contract test for the first-class analyze-issues skill.
#
# Promotes the analyze-mode reference (skills/run/references/analyze-mode.md)
# into a standalone skill at skills/analyze-issues/SKILL.md. This test asserts
# the SKILL.md exists, carries the expected frontmatter, and preserves every
# contract anchor previously asserted in tests/test-run-analyze-flag.sh, plus
# the NEW supersession category.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/analyze-issues/SKILL.md"
FAILED=0

want_in() {
  local file="$1" name="$2" pat="$3"
  if grep -qE -- "$pat" "$file"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found in $(basename "$file"): $pat)"
    FAILED=$((FAILED+1))
  fi
}

if [ ! -f "$SKILL" ]; then
  echo "  FAIL: skills/analyze-issues/SKILL.md exists"
  echo "FAILED: SKILL.md missing"
  exit 1
fi
echo "  PASS: skills/analyze-issues/SKILL.md exists"

# Frontmatter contract
want_in "$SKILL" "frontmatter name: analyze-issues"   '^name: analyze-issues'
want_in "$SKILL" "frontmatter has description"         '^description:'
want_in "$SKILL" "allowed-tools includes Bash"         '^allowed-tools:.*Bash'
want_in "$SKILL" "allowed-tools includes Agent"        '^allowed-tools:.*Agent'

# Preserved contract anchors (carried over from the old references file).
want_in "$SKILL" "argv-position parser spec mentions argv" 'argv position'
want_in "$SKILL" "mirrors --manual-merge parser pattern"   '--manual-merge'
want_in "$SKILL" "references scripts/analyze-issues.sh"     'scripts/analyze-issues\.sh'
want_in "$SKILL" "asserts no-mutation contract"            'No mutations'
want_in "$SKILL" "documents early-exit / skip flow"        'SKIPS classify / plan / execute'
want_in "$SKILL" "dispatches general-purpose subagent"     "Agent\\(subagent_type='general-purpose'"
want_in "$SKILL" "references shortlist path placeholder"   'SHORTLIST_PATH'
want_in "$SKILL" "duplicate-candidates output table column" '## Duplicate candidates'
want_in "$SKILL" "tracker-fits output table column"        'Standalones that fit an existing tracker'
want_in "$SKILL" "documents missing-label table heading"   '## Issues missing labels'

# NEW supersession category
want_in "$SKILL" "documents supersession_candidates JSON key" 'supersession_candidates'
want_in "$SKILL" "supersession output table heading"          '## Possibly superseded by recent commits'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: analyze-issues skill matches contract"
