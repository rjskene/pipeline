#!/bin/bash
set -uo pipefail

# Assert skills/doctor/SKILL.md documents new residual checks and --fix residual flag.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$SCRIPT_DIR/../skills/doctor/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  echo "FAIL: $SKILL not found"
  exit 1
fi

# (a) Three new check bullets exist by name
if grep -qE '^- `claude_md_residual' "$SKILL"; then
  pass_msg "claude_md_residual bullet present"
else
  fail_msg "claude_md_residual bullet missing"
fi

if grep -qE '^- `settings_residual' "$SKILL"; then
  pass_msg "settings_residual bullet present"
else
  fail_msg "settings_residual bullet missing"
fi

if grep -qE '^- `skill_files_residual' "$SKILL"; then
  pass_msg "skill_files_residual bullet present"
else
  fail_msg "skill_files_residual bullet missing"
fi

# (b) Mutating actions section + --fix residual subheading
if grep -qE '^## Mutating actions' "$SKILL"; then
  pass_msg "Mutating actions heading present"
else
  fail_msg "Mutating actions heading missing"
fi

if grep -qE '^### `--fix residual`' "$SKILL"; then
  pass_msg "--fix residual subheading present"
else
  fail_msg "--fix residual subheading missing"
fi

if grep -qE '^### `--fix labels`' "$SKILL"; then
  pass_msg "--fix labels subheading present"
else
  fail_msg "--fix labels subheading missing"
fi

# (c) Advisory text helper mention
if grep -q '_advisory-text.sh' "$SKILL"; then
  pass_msg "_advisory-text.sh helper mentioned"
else
  fail_msg "_advisory-text.sh helper not mentioned"
fi

echo
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
