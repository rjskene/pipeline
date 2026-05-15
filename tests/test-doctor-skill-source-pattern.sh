#!/bin/bash
set -uo pipefail

# Locks the source-then-use pattern in skills/doctor/SKILL.md:
#   1. `source ... _resolve-plugin-root.sh` line is present.
#   2. The `bash ... /scripts/doctor.sh` invocation line is present AFTER it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
F="$SCRIPT_DIR/../skills/doctor/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SRC_LINE=$(grep -nE 'source [^ ]*_resolve-plugin-root\.sh' "$F" | head -n 1 | cut -d: -f1)
DOC_LINE=$(grep -nE 'bash .*/scripts/doctor\.sh' "$F" | head -n 1 | cut -d: -f1)

if [ -n "$SRC_LINE" ]; then
  pass_msg "skills/doctor/SKILL.md sources _resolve-plugin-root.sh"
else
  fail_msg "skills/doctor/SKILL.md does NOT source _resolve-plugin-root.sh"
fi

if [ -n "$DOC_LINE" ]; then
  pass_msg "skills/doctor/SKILL.md invokes scripts/doctor.sh"
else
  fail_msg "skills/doctor/SKILL.md does NOT invoke scripts/doctor.sh"
fi

if [ -n "$SRC_LINE" ] && [ -n "$DOC_LINE" ] && [ "$SRC_LINE" -lt "$DOC_LINE" ]; then
  pass_msg "source line precedes doctor.sh invocation (line $SRC_LINE < $DOC_LINE)"
else
  fail_msg "source line does NOT precede doctor.sh invocation (src=$SRC_LINE doc=$DOC_LINE)"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
