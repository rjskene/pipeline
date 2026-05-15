#!/bin/bash
# Lint skills/run/SKILL.md for the FULL SEND --manual-merge parser,
# Step 8 auto-merge-default wiring, Step 9 conditional prose, and report
# table column introduced by issue #122.
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

want "Step 8 references helper or four conditions" 'scripts/auto-merge-gate.sh'
want "FULL SEND header documents argv position"    'manual-merge.* anywhere in argv'
want "Step 8 greps auto-merged footer prefix"      'Auto-merged: eval Approved \+ CI SUCCESS \+ MERGEABLE/CLEAN at'
want "Step 9 prose is conditional, not absolute"   'do NOT merge unless'
want "report table has Auto-merged column"         'Auto-merged\?'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run/SKILL.md auto-merge default contract met"
