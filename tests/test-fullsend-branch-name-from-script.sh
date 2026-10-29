#!/bin/bash
# Pins #1605: fullsend Step 5 names the branch setup-worktree.sh printed
# (suffix included) for later prompts, and the execute skill's branch-assert
# compares HEAD against that printed branch (suffix-only mismatch ⇒ continue;
# any other mismatch still STOPs).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FULLSEND="$SCRIPT_DIR/../skills/fullsend/SKILL.md"
EXECUTE="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

STEP5_LINE=$(grep -nE '^5\. \*\*Set up worktrees\*\*' "$FULLSEND" | head -1 | cut -d: -f1)
if [ -z "$STEP5_LINE" ]; then
  fail_msg "could not find '5. **Set up worktrees**' anchor in $FULLSEND"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi
WINDOW_END=$((STEP5_LINE + 30))
STEP5_WINDOW=$(sed -n "${STEP5_LINE},${WINDOW_END}p" "$FULLSEND")

# F1: Step 5 names the printed `Branch:` line and PIPELINE_BRANCH_SUFFIX.
inc
if echo "$STEP5_WINDOW" | grep -qF '`Branch:`' \
   && echo "$STEP5_WINDOW" | grep -qF 'PIPELINE_BRANCH_SUFFIX'; then
  pass_msg "F1 step 5 names the printed \`Branch:\` line and PIPELINE_BRANCH_SUFFIX"
else
  fail_msg "F1 step 5 window lacks \`Branch:\` and/or PIPELINE_BRANCH_SUFFIX"
fi

# F2: Step 5 forbids reusing the <branch-name> argument.
inc
if echo "$STEP5_WINDOW" | grep -qF 'never `<branch-name>`'; then
  pass_msg "F2 step 5 says never \`<branch-name>\`"
else
  fail_msg "F2 step 5 window lacks 'never \`<branch-name>\`'"
fi

ASSERT_LINE=$(grep -F '**Git-anchoring + branch-assert.**' "$EXECUTE" | head -1)
if [ -z "$ASSERT_LINE" ]; then
  fail_msg "could not find '**Git-anchoring + branch-assert.**' line in $EXECUTE"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

# X1: the branch-assert compares against the printed branch; suffix-only ⇒ continue.
inc
x1_ok=1
for tok in 'setup-worktree.sh' 'printed' '`-<suffix>`' 'continue'; do
  printf '%s\n' "$ASSERT_LINE" | grep -qF -- "$tok" || { x1_ok=0; fail_msg "X1 branch-assert line lacks '$tok'"; }
done
[ "$x1_ok" -eq 1 ] && pass_msg "X1 branch-assert names the printed branch and the suffix-only continue"

# X2: any other mismatch still stops.
inc
x2_ok=1
for tok in 'STOP and report' 'symbolic-ref --short HEAD'; do
  printf '%s\n' "$ASSERT_LINE" | grep -qF -- "$tok" || { x2_ok=0; fail_msg "X2 branch-assert line lacks '$tok'"; }
done
[ "$x2_ok" -eq 1 ] && pass_msg "X2 branch-assert still STOPs on other mismatches"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
