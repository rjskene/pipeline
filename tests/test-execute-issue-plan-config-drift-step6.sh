#!/usr/bin/env bash
# Test: execute-issue-plan SKILL.md Step 6 does NOT invoke check-config-drift.sh (#1508).
#
# Config drift has ONE pre-PR call site: Step 9a's
# `scripts/check-cross-cutting-guards.sh`, which already runs
# `check-config-drift.sh` internally (consumer-root aware). The former bare
# `&& bash scripts/check-config-drift.sh` link in the Step 6b fence (and the 6e
# paragraph) only resolved inside this repo, so #1508 removed it.
#
# Asserts:
#  (a) The Step 6 region (`6. **Validate` → `7. **Self-review`) does NOT
#      contain `scripts/check-config-drift.sh`.
#  (b) Step 6 still carries the always-run `check-cross-cutting-guards` note,
#      pointing at the single Step 9a guard surface.

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

# (a) No standalone config-drift invocation in Step 6.
if printf '%s\n' "$STEP6" | grep -qF 'scripts/check-config-drift.sh'; then
  echo "FAIL: Step 6 still invokes 'scripts/check-config-drift.sh'"
  echo "Expected: config drift runs once, via Step 9a check-cross-cutting-guards.sh (#1508)"
  exit 1
fi

# (b) The always-run cross-cutting guards note survives.
if ! printf '%s\n' "$STEP6" | grep -qF 'check-cross-cutting-guards'; then
  echo "FAIL: Step 6 lost the always-run 'check-cross-cutting-guards' note"
  exit 1
fi

echo "PASS: execute-issue-plan Step 6 has no standalone check-config-drift link; cross-cutting guards note present"
