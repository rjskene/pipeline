#!/bin/bash
set -uo pipefail
#
# Contract test (issue #763): the legacy "Full Send — back-compat delegator"
# is GONE. The read-only /pipeline:status skill must not delegate to fullsend,
# and the thin /pipeline:run alias delegates to status (not fullsend) too.
# Autonomous advancement starts at /pipeline:fullsend directly.
#
# Asserts, for BOTH skills/status/SKILL.md AND the skills/run/SKILL.md alias:
#   (a) neither contains `Skill(skill: "pipeline:fullsend")`
#   (b) the "Full Send — back-compat delegator" section is gone from status

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATUS="$REPO_ROOT/skills/status/SKILL.md"
ALIAS="$REPO_ROOT/skills/run/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

for f in "$STATUS" "$ALIAS"; do
  if [ ! -f "$f" ]; then
    fail_msg "expected file not found: $f"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
  fi
done

# (a) Neither status nor the alias delegates to fullsend.
if grep -qF 'Skill(skill: "pipeline:fullsend"' "$STATUS"; then
  fail_msg "skills/status/SKILL.md delegates to pipeline:fullsend (full-send delegator must be gone)"
else
  pass_msg "skills/status/SKILL.md has no pipeline:fullsend delegation"
fi

if grep -qF 'Skill(skill: "pipeline:fullsend"' "$ALIAS"; then
  fail_msg "skills/run/SKILL.md alias delegates to pipeline:fullsend (alias forwards to status only)"
else
  pass_msg "skills/run/SKILL.md alias has no pipeline:fullsend delegation"
fi

# (b) The "Full Send — back-compat delegator" section is gone from status.
if grep -qiE 'Full Send.*back-compat delegator|back-compat delegator' "$STATUS"; then
  fail_msg "skills/status/SKILL.md still carries the 'Full Send — back-compat delegator' section"
else
  pass_msg "no 'Full Send — back-compat delegator' section in skills/status/SKILL.md"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
