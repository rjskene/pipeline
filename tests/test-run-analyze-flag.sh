#!/bin/bash
# Lint skills/run/SKILL.md and skills/analyze-issues/SKILL.md for the
# /pipeline:run --analyze prose contract introduced by issue #138.
#
# After issue #340, the full analyze-mode spec moved out of SKILL.md into
# skills/run/references/analyze-mode.md. The follow-up promoted that reference
# into a first-class skill at skills/analyze-issues/SKILL.md, and SKILL.md now
# delegates to it. This test asserts the SKILL.md delegator block + Shortcuts
# row point at the new skill, that the deep contract anchors live in the new
# skill, and that the old references/analyze-mode.md anchors are GONE from
# SKILL.md.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/status/SKILL.md"
NEW_SKILL="${ROOT}/skills/analyze-issues/SKILL.md"
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

want_not_in() {
  local file="$1" name="$2" pat="$3"
  if ! grep -qE -- "$pat" "$file"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern unexpectedly found in $(basename "$file"): $pat)"
    FAILED=$((FAILED+1))
  fi
}

# SKILL.md must still document the flag at the orchestrator decision-tree level
# (Shortcuts table + a delegator block invoking the analyze-issues skill).
want_in "$SKILL" "SKILL.md documents --analyze flag"            '--analyze'
want_in "$SKILL" "SKILL.md delegates via Skill(pipeline:analyze-issues)" 'Skill\(skill: "pipeline:analyze-issues"\)'
want_in "$SKILL" "Shortcuts row points at analyze-issues skill" 'skills/analyze-issues/SKILL\.md'

# The deep references/analyze-mode.md anchors are GONE from SKILL.md — the
# inline analyze flow no longer lives here. (Note: the bare
# Agent(subagent_type='general-purpose' string legitimately remains in SKILL.md
# for PATH A/B dispatch routing; the negative assertions below target the
# analyze-specific anchors only.)
want_not_in "$SKILL" "SKILL.md no longer links to references/analyze-mode.md" 'references/analyze-mode\.md'
want_not_in "$SKILL" "SKILL.md no longer dispatches the analyze-hygiene subagent inline" 'analyze open-issue hygiene shortlist'
want_not_in "$SKILL" "SKILL.md no longer references the analyze shortlist path" 'SHORTLIST_PATH'

# The full contract lives in skills/analyze-issues/SKILL.md. Every anchor that
# previously had to exist inline now has to exist there.
want_in "$NEW_SKILL" "argv-position parser spec mentions argv"    'argv position'
want_in "$NEW_SKILL" "mirrors --manual-merge parser pattern"      '--manual-merge'
want_in "$NEW_SKILL" "references scripts/analyze-issues.sh"       'scripts/analyze-issues\.sh'
want_in "$NEW_SKILL" "asserts no-mutation contract"               'No mutations'
want_in "$NEW_SKILL" "documents early-exit / skip flow"           'SKIPS classify / plan / execute'
want_in "$NEW_SKILL" "dispatches general-purpose subagent"        "Agent\\(subagent_type='general-purpose'"
want_in "$NEW_SKILL" "references shortlist path placeholder"      'SHORTLIST_PATH'
want_in "$NEW_SKILL" "duplicate-candidates output table column"   '## Duplicate candidates'
want_in "$NEW_SKILL" "tracker-fits output table column"           'Standalones that fit an existing tracker'
want_in "$NEW_SKILL" "documents missing-label table heading"      '## Issues missing labels'
want_in "$NEW_SKILL" "documents missing_label_candidates JSON"    'missing_label_candidates'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run skill --analyze prose matches contract (SKILL.md delegator + skills/analyze-issues/SKILL.md body)"
