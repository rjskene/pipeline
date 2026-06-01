#!/bin/bash
# Regression guard: the /pipeline:init skill + backing script must ship in the
# tree. A renamed/emptied skill, a deleted script, or a non-invocable script
# trips this guard. Harness idiom (pass_msg/fail_msg counters, nonzero exit on
# any failure) borrowed from tests/test-init-script.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# 1. skills/init/SKILL.md is a regular file.
test -f "$ROOT/skills/init/SKILL.md" \
  && pass_msg "skills/init/SKILL.md is a regular file" \
  || fail_msg "skills/init/SKILL.md missing or not a regular file"

# 2. scripts/init.sh is a regular file.
test -f "$ROOT/scripts/init.sh" \
  && pass_msg "scripts/init.sh is a regular file" \
  || fail_msg "scripts/init.sh missing or not a regular file"

# 3. scripts/init.sh is executable, or at least readable/invocable via bash.
{ test -x "$ROOT/scripts/init.sh" || test -r "$ROOT/scripts/init.sh"; } \
  && pass_msg "scripts/init.sh is executable or readable" \
  || fail_msg "scripts/init.sh neither executable nor readable"

# 4. skills/init/SKILL.md body advertises the literal command id pipeline:init.
grep -q "pipeline:init" "$ROOT/skills/init/SKILL.md" \
  && pass_msg "skills/init/SKILL.md mentions pipeline:init" \
  || fail_msg "skills/init/SKILL.md missing literal pipeline:init"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
