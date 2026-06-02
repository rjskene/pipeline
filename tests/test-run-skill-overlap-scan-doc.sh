#!/bin/bash
# Guard against doc drift: the pre-merge overlap-scan helper functions must be
# referenced so operators discover detect-merge-overlap.sh.
# #763: the run→status rename moved the merge-orchestration overlap scan out of
# the old /pipeline:run skill into fullsend's "## Merge orchestration (reference)"
# (the read-only /pipeline:status skill performs no merges).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/fullsend/SKILL.md"
if ! grep -q 'detect_merge_overlap' "$SKILL"; then
  echo "FAIL: skills/fullsend/SKILL.md does not reference detect_merge_overlap"
  exit 1
fi
if ! grep -q 'recommend_merge_order' "$SKILL"; then
  echo "FAIL: skills/fullsend/SKILL.md does not reference recommend_merge_order"
  exit 1
fi
echo "PASS: overlap scan documented in fullsend skill"
