#!/bin/bash
# Lint skills/run/SKILL.md and references/analyze-mode.md for the
# /pipeline:run --analyze prose contract introduced by issue #138.
#
# After issue #340, the full analyze-mode spec moved out of SKILL.md into
# skills/run/references/analyze-mode.md. This test now asserts the
# SKILL.md stub still links to the reference file, and that all
# previously-inline contract anchors live in the reference file.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/run/SKILL.md"
REF="${ROOT}/skills/run/references/analyze-mode.md"
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

# SKILL.md must still document the flag at the orchestrator decision-tree level
# (Shortcuts table + the stub section linking to references/analyze-mode.md).
want_in "$SKILL" "SKILL.md documents --analyze flag"            '--analyze'
want_in "$SKILL" "SKILL.md links to references/analyze-mode.md" 'references/analyze-mode\.md'

# The full contract lives in references/analyze-mode.md. Every anchor that
# previously had to exist inline now has to exist there.
want_in "$REF" "argv-position parser spec mentions argv"    'argv position'
want_in "$REF" "mirrors --manual-merge parser pattern"      '--manual-merge'
want_in "$REF" "references scripts/analyze-issues.sh"       'scripts/analyze-issues\.sh'
want_in "$REF" "asserts no-mutation contract"               'No mutations'
want_in "$REF" "documents early-exit / skip flow"           'SKIPS classify / plan / execute'
want_in "$REF" "dispatches general-purpose subagent"        "Agent\\(subagent_type='general-purpose'"
want_in "$REF" "references shortlist path placeholder"      'SHORTLIST_PATH'
want_in "$REF" "duplicate-candidates output table column"   '## Duplicate candidates'
want_in "$REF" "tracker-fits output table column"           'Standalones that fit an existing tracker'
want_in "$REF" "documents missing-label table heading"      '## Issues missing labels'
want_in "$REF" "documents missing_label_candidates JSON"    'missing_label_candidates'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run skill --analyze prose matches contract (SKILL.md stub + references/analyze-mode.md body)"
