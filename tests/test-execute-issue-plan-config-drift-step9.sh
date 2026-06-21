#!/usr/bin/env bash
# Test: execute-issue-plan SKILL.md Step 9 includes a check-config-drift pre-PR guard.
#
# Asserts:
#  (a) Step 9 (the Open a pull request block) references 'check-config-drift' so that
#      undocumented PIPELINE_* vars introduced in a feature branch are caught pre-PR,
#      not only at CI (#1102).
#  (b) The reference is specific enough to invoke the script: 'scripts/check-config-drift.sh'
#      appears inside the Step 9 region.
#  (c) Abort guidance (undocumented PIPELINE_* drift) appears near the check-config-drift
#      reference so executors know the guard is a hard block, not a warning.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"

if [ ! -f "$SKILL" ]; then
  echo "FAIL: $SKILL not found"
  exit 1
fi

# Extract Step 9 region: from "9. **Open a pull request" up to (but not including) "10. **Mark as pr-open".
STEP9="$(awk '/^9\. \*\*Open a pull request/{f=1} /^10\. \*\*Mark as pr-open/{f=0} f' "$SKILL")"

if [ -z "$STEP9" ]; then
  echo "FAIL: could not extract Step 9 region from $SKILL"
  exit 1
fi

# (a) 'check-config-drift' must appear somewhere in Step 9.
if ! printf '%s\n' "$STEP9" | grep -q 'check-config-drift'; then
  echo "FAIL: Step 9 does not reference 'check-config-drift'"
  echo "Expected: 'bash scripts/check-config-drift.sh' (exit 0) added to the Step 9 pre-PR block"
  exit 1
fi

# (b) The full script path 'scripts/check-config-drift.sh' must appear in Step 9.
if ! printf '%s\n' "$STEP9" | grep -q 'scripts/check-config-drift.sh'; then
  echo "FAIL: Step 9 references 'check-config-drift' but not 'scripts/check-config-drift.sh'"
  echo "Expected explicit invocation: 'bash scripts/check-config-drift.sh'"
  exit 1
fi

# (c) Abort guidance must appear near the check-config-drift reference.
# Accept 'ABORT' or 'undocumented' within the Step 9 block.
if ! printf '%s\n' "$STEP9" | grep -qiE 'ABORT|undocumented'; then
  echo "FAIL: Step 9 check-config-drift entry missing abort guidance"
  echo "Expected: ABORT message indicating undocumented PIPELINE_* drift near the invocation"
  exit 1
fi

echo "PASS: execute-issue-plan Step 9 references check-config-drift with abort guidance"
