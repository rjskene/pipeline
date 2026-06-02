#!/bin/bash
# Asserts that the "Full Send — autonomous end-to-end execution" flow
# has been extracted from skills/run/SKILL.md into its own skill at
# skills/fullsend/SKILL.md, and that skills/run/SKILL.md only retains
# a thin back-compat delegator pointing at the new skill.
#
# Introduced by issue #143.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FS_SKILL="${ROOT}/skills/fullsend/SKILL.md"
RUN_SKILL="${ROOT}/skills/run/SKILL.md"
FAILED=0

want_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (file not found: $path)"
    FAILED=$((FAILED+1))
  fi
}

want_match() {
  local name="$1" path="$2" pat="$3"
  if [ -f "$path" ] && grep -qF -- "$pat" "$path"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found in $path: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want_no_match() {
  local name="$1" path="$2" pat="$3"
  if [ ! -f "$path" ]; then
    echo "  FAIL: $name (file missing: $path)"
    FAILED=$((FAILED+1))
    return
  fi
  if grep -qF -- "$pat" "$path"; then
    echo "  FAIL: $name (unexpected pattern still in $path: $pat)"
    FAILED=$((FAILED+1))
  else
    echo "  PASS: $name"
  fi
}

# 1. Fullsend skill exists.
want_file "skills/fullsend/SKILL.md exists" "$FS_SKILL"

# 2. Fullsend skill has frontmatter name.
want_match "fullsend skill frontmatter declares name: fullsend" "$FS_SKILL" "name: fullsend"

# 3. Step 0a wave-plan invocation moved verbatim into fullsend.
want_match "fullsend skill contains plan-waves.sh invocation" "$FS_SKILL" 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh'

# 4. Step 8 greenlight matrix moved verbatim into fullsend.
want_match "fullsend skill contains FULL SEND COMPLETE banner" "$FS_SKILL" "FULL SEND COMPLETE"
want_match "fullsend skill contains Auto-merged? column" "$FS_SKILL" "Auto-merged?"

# 5. DELETED for #763: the old /pipeline:run "Full Send — back-compat delegator"
#    delegated to pipeline:fullsend. The run→status rename retired that
#    delegator — /pipeline:run is now a thin DEPRECATED ALIAS that forwards to
#    the read-only /pipeline:status (NOT fullsend), so
#    `Skill(skill: "pipeline:fullsend"` is gone from the alias by design.
#    Verified obsolete: see tests/test-run-alias-delegates.sh +
#    tests/test-status-no-full-send-delegator.sh, which assert the alias
#    delegates to status and never to fullsend.

# 6. Run skill no longer contains the moved Step 0a wave-plan content
#    (regression guard against content forking).
want_no_match "run skill no longer contains plan-waves.sh invocation" "$RUN_SKILL" 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: fullsend skill extraction contract met"
