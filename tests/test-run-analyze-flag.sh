#!/bin/bash
# Lint skills/run/SKILL.md for the /pipeline:run --analyze prose contract
# introduced by issue #138.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/run/SKILL.md"
FAILED=0

want() {
  local name="$1" pat="$2"
  if grep -qE -- "$pat" "$SKILL"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want "documents --analyze flag"                   '--analyze'
want "argv-position parser spec mentions argv"    'argv position'
want "mirrors --manual-merge parser pattern"      '--manual-merge'
want "references scripts/analyze-issues.sh"       'scripts/analyze-issues\.sh'
want "asserts no-mutation contract"               'No mutations'
want "documents early-exit / skip flow"           'SKIPS classify / plan / execute'
want "dispatches general-purpose subagent"        "Agent\\(subagent_type='general-purpose'"
want "references shortlist path placeholder"      'SHORTLIST_PATH'
want "duplicate-candidates output table column"   '## Duplicate candidates'
want "tracker-fits output table column"           'Standalones that fit an existing tracker'
want "documents missing-label table heading"      '## Issues missing labels'
want "documents missing_label_candidates JSON"    'missing_label_candidates'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run skill --analyze prose matches contract"
