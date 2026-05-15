#!/bin/bash
# Lint skills/run/SKILL.md for the FULL SEND --manual-merge parser,
# Step 8 auto-merge-default wiring, Step 9 conditional prose, and report
# table column introduced by issue #122.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Issue #143: full-send-specific contract markers moved from skills/run/SKILL.md
# to skills/fullsend/SKILL.md. Markers that live on the merge-orchestration
# step (Step 8 of the run skill, still active in interactive mode) stay on the
# run skill.
RUN_SKILL="${ROOT}/skills/run/SKILL.md"
FS_SKILL="${ROOT}/skills/fullsend/SKILL.md"
FAILED=0

want_in() {
  local skill="$1" name="$2" pat="$3"
  if grep -qE -- "$pat" "$skill"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found in $skill: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want_in "$RUN_SKILL" "run skill Step 8 references helper or four conditions" 'scripts/auto-merge-gate.sh'
want_in "$FS_SKILL"  "fullsend FULL SEND header documents argv position"    'manual-merge.* anywhere in argv'
want_in "$RUN_SKILL" "run skill Step 8 greps auto-merged footer prefix"     'Auto-merged: eval Approved \+ CI SUCCESS \+ MERGEABLE/CLEAN at'
want_in "$FS_SKILL"  "fullsend Step 9 prose is conditional, not absolute"   'do NOT merge unless'
want_in "$RUN_SKILL" "run skill report table has Auto-merged column"        'Auto-merged\?'
want_in "$FS_SKILL"  "fullsend report table has Auto-merged column"         'Auto-merged\?'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run/SKILL.md auto-merge default contract met"
