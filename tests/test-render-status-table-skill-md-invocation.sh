#!/bin/bash
set -uo pipefail

# Verifies that skills/run/SKILL.md no longer carries the prose render
# spec (which migrated into scripts/render-status-table.sh in #343) and
# that the renderer invocation block is present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$SCRIPT_DIR/../skills/run/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); echo "    $2"; }
inc()      { TESTS=$((TESTS + 1)); }

# Anchors that previously lived in step 3's prose render rules but should
# now live ONLY inside scripts/render-status-table.sh / its tests.
ANCHORS_REMOVED=(
  "(all children closed — pending auto-close)"
  "NOTES (non-default)"
  "RELEASE PRs"
)

# Header anchors that ALSO need to disappear from prose; their data still
# lives in code but the visible "ASCII layout example" block must be gone.
HEADER_ANCHORS_REMOVED=(
  "PIPELINE STATUS —"
  "EPICS"
  "ORPHANS"
)

inc
if [ ! -f "$SKILL_MD" ]; then
  fail_msg "skills/run/SKILL.md exists" "missing: $SKILL_MD"
else
  pass_msg "skills/run/SKILL.md exists"

  for anchor in "${ANCHORS_REMOVED[@]}"; do
    inc
    if grep -qF "$anchor" "$SKILL_MD"; then
      fail_msg "SKILL.md no longer contains anchor: $anchor" \
        "$(grep -n "$anchor" "$SKILL_MD" | head -3)"
    else
      pass_msg "SKILL.md no longer contains anchor: $anchor"
    fi
  done

  for anchor in "${HEADER_ANCHORS_REMOVED[@]}"; do
    inc
    if grep -qF "$anchor" "$SKILL_MD"; then
      fail_msg "SKILL.md no longer contains layout anchor: $anchor" \
        "$(grep -n "$anchor" "$SKILL_MD" | head -3)"
    else
      pass_msg "SKILL.md no longer contains layout anchor: $anchor"
    fi
  done

  inc
  # Renderer invocation present.
  if grep -q 'scripts/render-status-table.sh' "$SKILL_MD"; then
    pass_msg "SKILL.md invokes scripts/render-status-table.sh"
  else
    fail_msg "SKILL.md invokes scripts/render-status-table.sh" \
      "no reference to render-status-table.sh in $SKILL_MD"
  fi

  inc
  # Input partitioning block (TRACKER_ISSUES / READY_ISSUES) preserved —
  # that's orchestrator behavior, not render spec.
  if grep -q 'BEGIN-TRACKER-FILTER' "$SKILL_MD"; then
    pass_msg "SKILL.md preserves BEGIN-TRACKER-FILTER block"
  else
    fail_msg "SKILL.md preserves BEGIN-TRACKER-FILTER block" \
      "tracker-filter block missing from $SKILL_MD"
  fi

  inc
  # Decision-tree (step 4 "Propose ONE action") preserved.
  if grep -q '^4\. \*\*Propose ONE action\*\*' "$SKILL_MD"; then
    pass_msg "SKILL.md preserves step 4 (Propose ONE action decision tree)"
  else
    fail_msg "SKILL.md preserves step 4 (Propose ONE action decision tree)" \
      "step 4 heading missing from $SKILL_MD"
  fi
fi

echo ""
echo "=========================================================="
echo "TOTAL: $TESTS  PASS: $PASS  FAIL: $FAIL"
echo "=========================================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
