#!/bin/bash
# Regression guard for the deleted analyze-mode reference.
#
# After issue #340 the analyze-mode spec was promoted out of
# skills/run/references/analyze-mode.md into the first-class
# skills/analyze-issues/SKILL.md. This test FAILS if either:
#   - skills/run/references/analyze-mode.md still exists, OR
#   - any tracked file under skills/ still links to references/analyze-mode.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STALE_FILE="${ROOT}/skills/run/references/analyze-mode.md"
SELF="$(basename "$0")"
FAILED=0

# (1) The migrated reference file must be gone.
if [ -e "$STALE_FILE" ]; then
  echo "  FAIL: skills/run/references/analyze-mode.md still exists (should be deleted)"
  FAILED=$((FAILED+1))
else
  echo "  PASS: skills/run/references/analyze-mode.md is gone"
fi

# (2) No tracked file under skills/ may still link to references/analyze-mode.
#     Exclude .git, .claude/logs, and this test file itself (its mention of the
#     path string is the checker, not a live link).
HITS="$(grep -rn "references/analyze-mode" "${ROOT}/skills" \
          --exclude-dir=.git \
          --exclude-dir=logs \
          --exclude="$SELF" 2>/dev/null || true)"
if [ -n "$HITS" ]; then
  echo "  FAIL: stale link(s) to references/analyze-mode found under skills/:"
  echo "$HITS"
  FAILED=$((FAILED+1))
else
  echo "  PASS: no stale links to references/analyze-mode under skills/"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: analyze-mode reference fully retired"
