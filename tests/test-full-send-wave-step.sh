#!/bin/bash
set -euo pipefail

# Assert that skills/run/SKILL.md's Full Send section has a "Step 0a" wave-plan
# instruction that runs BEFORE the existing "1. **Plan**" step and references
# scripts/plan-waves.sh. Also guard against accidental rewrites of the
# existing step 1 prose (anchor sentence) so the #63 patch stays small and
# does not conflict with #31 / #122.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Issue #143: the autonomous full-send flow was extracted from skills/run/SKILL.md
# into its own skill at skills/fullsend/SKILL.md. The Step 0a wave-plan content
# lives there now; skills/run/SKILL.md retains only a delegator stub.
SKILL_PATH="$SCRIPT_DIR/../skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_PATH" ]; then
  fail_msg "SKILL.md not found at $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

FS_START_LINE=$(grep -nE '^(#+ )?Full Send' "$SKILL_PATH" | head -1 | cut -d: -f1)
STEP1_LINE=$(awk 'NR>=fs && /^1\. \*\*Plan\*\*/ {print NR; exit}' fs="$FS_START_LINE" "$SKILL_PATH")

if [ -z "$FS_START_LINE" ]; then
  fail_msg "could not find 'Full Send' heading"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"; exit 1
fi
if [ -z "$STEP1_LINE" ]; then
  fail_msg "could not find '1. **Plan**' step inside Full Send"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"; exit 1
fi

SECTION_BETWEEN=$(sed -n "${FS_START_LINE},${STEP1_LINE}p" "$SKILL_PATH")

# 1. Step 0a header/list-item between Full Send heading and step 1
inc
if echo "$SECTION_BETWEEN" | grep -qE '(^###[[:space:]].*Step 0a|^0a\.|^\*\*0a\.)'; then
  pass_msg "Step 0a appears between 'Full Send' heading and '1. **Plan**'"
else
  fail_msg "Step 0a not found between Full Send heading (line $FS_START_LINE) and step 1 (line $STEP1_LINE)"
fi

# 2. The Step 0a content references plan-waves.sh literally
inc
if echo "$SECTION_BETWEEN" | grep -qF 'plan-waves.sh'; then
  pass_msg "Step 0a section references plan-waves.sh"
else
  fail_msg "Step 0a section does not reference plan-waves.sh"
fi

# 3. Existing step 1 anchor sentence is preserved verbatim (no rewrites).
# This guards merge surface with #31 / #122 — see plan.
inc
ANCHOR='before dispatching plan-issue, run `/pipeline:classify-issue N` for every ready issue that lacks a fresh Classification comment'
if grep -qF "$ANCHOR" "$SKILL_PATH"; then
  pass_msg "step 1 anchor sentence preserved verbatim"
else
  fail_msg "step 1 anchor sentence missing or modified: '$ANCHOR'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
