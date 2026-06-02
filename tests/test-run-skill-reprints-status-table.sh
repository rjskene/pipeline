#!/bin/bash
# Regression guard for issues #423 and #834:
#
# #423 established that the /pipeline:run orchestrator must surface the rendered
# status table in chat (bash tool stdout alone is hidden inside a folded tool
# call). #834 corrected HOW: the original "reprint the rendered table as plain
# text" mandate drifted into a janky, reformatted chat summary — a lossy recap
# standing in for the deterministic renderer output. The fix is verbatim-paste-
# only: the orchestrator pastes the renderer's EXACT stdout into a SINGLE fenced
# code block, with no reformatting / prose-restatement / summary of rows.
#
# This test asserts, in BOTH the SKILL.md Step 3 block and the
# references/status-table.md Invocation block:
#   (a) the verbatim-paste-into-a-fenced-code-block directive is PRESENT, and
#   (b) the old soft "reprint ... as plain text" wording is GONE (it is the very
#       phrasing that licensed the drift).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SKILL="${ROOT}/skills/run/SKILL.md"
STATUS_REF="${ROOT}/skills/run/references/status-table.md"

# (a) The verbatim-paste directive must be present in both contract sites.
WANT_MARKER='verbatim into a single fenced code block'
# (b) The drift-licensing wording must be absent from both contract sites.
BANNED_MARKERS=(
  'reprint the rendered table'
  'reprint the rendered status table'
  'reprint the rendered table as plain text'
  'as plain text inside its assistant reply'
)

FAILED=0

want_marker() {
  local file="$1" name="$2"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $name (file not found: $file)"
    FAILED=$((FAILED+1))
    return
  fi
  if grep -qF -- "$WANT_MARKER" "$file"; then
    echo "  PASS: $name (verbatim-paste directive present)"
  else
    echo "  FAIL: $name (directive not found in $file: '$WANT_MARKER')"
    FAILED=$((FAILED+1))
  fi
}

reject_banned() {
  local file="$1" name="$2"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $name (file not found: $file)"
    FAILED=$((FAILED+1))
    return
  fi
  local banned hit=0
  for banned in "${BANNED_MARKERS[@]}"; do
    if grep -qiF -- "$banned" "$file"; then
      echo "  FAIL: $name (banned soft-reprint wording still present: '$banned')"
      hit=1
      FAILED=$((FAILED+1))
    fi
  done
  [ "$hit" -eq 0 ] && echo "  PASS: $name (no banned soft-reprint wording)"
}

want_marker "$RUN_SKILL"  "skills/run/SKILL.md mandates verbatim paste"
want_marker "$STATUS_REF" "skills/run/references/status-table.md mandates verbatim paste"
reject_banned "$RUN_SKILL"  "skills/run/SKILL.md drops soft-reprint wording"
reject_banned "$STATUS_REF" "skills/run/references/status-table.md drops soft-reprint wording"

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run skill mandates verbatim-paste of renderer stdout, bans reformatted summary"
