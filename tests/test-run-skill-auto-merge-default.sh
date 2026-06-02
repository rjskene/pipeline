#!/bin/bash
# Lint skills/run/SKILL.md for the FULL SEND --manual-merge parser,
# Step 8 auto-merge-default wiring, Step 9 conditional prose, and report
# table column introduced by issue #122.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Issue #143: full-send-specific contract markers moved from the old /pipeline:run
# skill to skills/fullsend/SKILL.md.
# #763: the run→status rename moved the REMAINING auto-merge wiring out of the
# old run skill too — the read-only /pipeline:status skill carries no auto-merge
# gate. The Step-8 auto-merge-gate.sh invocation and the report-table Auto-merged
# column now live in fullsend; the `Auto-merged: ...` confirmation FOOTER (fired
# by the evaluator's Step 11 gate) lives in skills/evaluate-issue-pr/SKILL.md.
FS_SKILL="${ROOT}/skills/fullsend/SKILL.md"
EVAL_SKILL="${ROOT}/skills/evaluate-issue-pr/SKILL.md"
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

want_in "$FS_SKILL"   "fullsend Step 8 references auto-merge-gate.sh helper"    'scripts/auto-merge-gate.sh'
want_in "$FS_SKILL"   "fullsend FULL SEND header documents argv position"      'manual-merge.* anywhere in argv'
want_in "$EVAL_SKILL" "evaluate-issue-pr emits auto-merged footer prefix"      'Auto-merged: eval Approved \+ CI SUCCESS \+ MERGEABLE/CLEAN at'
want_in "$FS_SKILL"   "fullsend Step 9 prose is conditional, not absolute"     'do NOT merge unless'
want_in "$FS_SKILL"   "fullsend report table has Auto-merged column"           'Auto-merged\?'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run/SKILL.md auto-merge default contract met"
