#!/bin/bash
# Regression guard for issue #423:
# The /pipeline:run orchestrator MUST reprint the rendered status table into
# its assistant reply text — bash tool stdout alone is not visible to the user
# without expanding the tool call. This test asserts the directive prose is
# present in both the SKILL.md Step 3 block and the references/status-table.md
# Invocation block.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SKILL="${ROOT}/skills/run/SKILL.md"
STATUS_REF="${ROOT}/skills/run/references/status-table.md"
MARKER='MUST reprint the rendered table'
FAILED=0

want_marker() {
  local file="$1" name="$2"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $name (file not found: $file)"
    FAILED=$((FAILED+1))
    return
  fi
  if grep -qF -- "$MARKER" "$file"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (marker phrase not found in $file: '$MARKER')"
    FAILED=$((FAILED+1))
  fi
}

want_marker "$RUN_SKILL"  "skills/run/SKILL.md contains reprint directive"
want_marker "$STATUS_REF" "skills/run/references/status-table.md contains reprint directive"

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run skill mandates orchestrator reprint of status table in assistant reply"
