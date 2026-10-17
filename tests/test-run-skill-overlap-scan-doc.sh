#!/bin/bash
# Guard against doc drift: the pre-merge overlap-scan helper functions must be
# referenced so operators discover detect-merge-overlap.sh.
# #763: the run→status rename moved the merge-orchestration overlap scan out of
# the old /pipeline:run skill into fullsend's "## Merge orchestration (reference)"
# (the read-only /pipeline:status skill performs no merges).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The section lives in fullsend SKILL.md; the scan itself is the
# scripts/fullsend-merge-order.sh helper it calls.
SKILL="$ROOT/skills/fullsend/SKILL.md"
HELPER="$ROOT/scripts/fullsend-merge-order.sh"
SECTION="$(awk '/^## Merge orchestration \(reference\)/{f=1; next} f && /^## /{f=0} f' "$SKILL")"
for fn in detect_merge_overlap recommend_merge_order; do
  if ! grep -q "$fn" <<<"$SECTION"; then
    echo "FAIL: fullsend SKILL.md '## Merge orchestration (reference)' does not reference $fn"
    exit 1
  fi
  if ! grep -vE '^[[:space:]]*#' "$HELPER" | grep -q "$fn"; then
    echo "FAIL: scripts/fullsend-merge-order.sh does not call $fn"
    exit 1
  fi
done
if ! grep -qF 'scripts/fullsend-merge-order.sh"' <<<"$SECTION"; then
  echo "FAIL: '## Merge orchestration (reference)' does not call scripts/fullsend-merge-order.sh"
  exit 1
fi
echo "PASS: overlap scan documented in fullsend skill"
