#!/bin/bash
# Guard against doc drift: the run skill's Step 7 must reference the pre-merge
# overlap-scan helper functions so operators discover detect-merge-overlap.sh.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if ! grep -q 'detect_merge_overlap' "$ROOT/skills/run/SKILL.md"; then
  echo "FAIL: skills/run/SKILL.md does not reference detect_merge_overlap"
  exit 1
fi
if ! grep -q 'recommend_merge_order' "$ROOT/skills/run/SKILL.md"; then
  echo "FAIL: skills/run/SKILL.md does not reference recommend_merge_order"
  exit 1
fi
echo "PASS: overlap scan documented in run skill"
