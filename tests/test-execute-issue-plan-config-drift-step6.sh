#!/usr/bin/env bash
# Test: execute-issue-plan SKILL.md Step 6 includes a check-config-drift validation step.
#
# Asserts:
#  (a) Step 6 (the Validate block) references 'check-config-drift' so that a new
#      PIPELINE_* variable introduced in a feature branch is caught in-leaf, not
#      only at CI.
#  (b) The reference is specific enough to invoke the script: 'scripts/check-config-drift.sh'
#      appears inside the Step 6 region.
#  (c) Fix guidance (document-or-allowlist) appears near the check-config-drift reference
#      so executors know how to resolve a finding.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"

if [ ! -f "$SKILL" ]; then
  echo "FAIL: $SKILL not found"
  exit 1
fi

# Extract Step 6 region: from "6. **Validate" up to (but not including) "7. **Self-review".
STEP6="$(awk '/^6\. \*\*Validate/{f=1} /^7\. \*\*Self-review/{f=0} f' "$SKILL")"

if [ -z "$STEP6" ]; then
  echo "FAIL: could not extract Step 6 region from $SKILL"
  exit 1
fi

# (a) 'check-config-drift' must appear somewhere in Step 6.
if ! printf '%s\n' "$STEP6" | grep -q 'check-config-drift'; then
  echo "FAIL: Step 6 does not reference 'check-config-drift'"
  echo "Expected: 'bash scripts/check-config-drift.sh' (exit 0) added to the Step 6 validate block"
  exit 1
fi

# (b) The full script path 'scripts/check-config-drift.sh' must appear in Step 6.
if ! printf '%s\n' "$STEP6" | grep -q 'scripts/check-config-drift.sh'; then
  echo "FAIL: Step 6 references 'check-config-drift' but not 'scripts/check-config-drift.sh'"
  echo "Expected explicit invocation: 'bash scripts/check-config-drift.sh'"
  exit 1
fi

# (c) Fix guidance: 'allowlist' or 'pipeline.config.example' must appear near the reference.
# We accept either word within the Step 6 block.
if ! printf '%s\n' "$STEP6" | grep -qiE 'allowlist|pipeline\.config\.example'; then
  echo "FAIL: Step 6 check-config-drift entry missing fix guidance"
  echo "Expected: document-or-allowlist fix guidance near the check-config-drift invocation"
  exit 1
fi

echo "PASS: execute-issue-plan Step 6 references check-config-drift with fix guidance"
