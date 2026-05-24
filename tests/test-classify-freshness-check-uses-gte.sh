#!/bin/bash
set -euo pipefail

# Guard: the classification cache-freshness check must treat a same-second
# classify+label-bump as FRESH, not stale. Per issue #457, the bare strict-`>`
# conditional in skills/classify-issue/SKILL.md mis-flags a classification
# whose `## Classification` comment `createdAt` exactly equals the issue's
# `updatedAt` (same-second label bump) as stale, forcing a needless
# re-classification. The fix widens the conditional to greater-OR-equal.
#
# Asserts:
#   (a) skills/classify-issue/SKILL.md contains the OR-equality clause so
#       equality reads as fresh
#   (b) skills/classify-issue/SKILL.md no longer carries the bare strict-`>`
#       shape `[[ -n "$LATEST_CLASS_TS" && "$LATEST_CLASS_TS" > "$ISSUE_TS" ]]`
#   (c) both prose mentions (skills/run/SKILL.md and
#       skills/run/references/dispatch-routing.md) read `createdAt >=
#       issue.updatedAt`, and neither still carries the strict-`>` literal

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLASSIFY_PATH="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"
RUN_PATH="$SCRIPT_DIR/../skills/run/SKILL.md"
ROUTING_PATH="$SCRIPT_DIR/../skills/run/references/dispatch-routing.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$CLASSIFY_PATH" "$RUN_PATH" "$ROUTING_PATH"; do
  if [ ! -f "$f" ]; then
    echo "  FAIL: expected file not found at $f"
    exit 1
  fi
done

# (a) The conditional must treat equality as fresh (OR-equality clause present).
inc
if grep -qE '"\$LATEST_CLASS_TS" > "\$ISSUE_TS" \|\| "\$LATEST_CLASS_TS" == "\$ISSUE_TS"' "$CLASSIFY_PATH"; then
  pass_msg "classify-issue/SKILL.md treats same-second classification as fresh (OR-equality clause)"
else
  fail_msg "classify-issue/SKILL.md is missing the OR-equality clause (issue #457 regression)"
fi

# (b) The bare strict-`>` shape must NOT remain.
inc
if grep -qF '[[ -n "$LATEST_CLASS_TS" && "$LATEST_CLASS_TS" > "$ISSUE_TS" ]]' "$CLASSIFY_PATH"; then
  fail_msg "classify-issue/SKILL.md still carries the bare strict-\`>\` conditional (issue #457)"
else
  pass_msg "classify-issue/SKILL.md no longer carries the bare strict-\`>\` conditional"
fi

# (c) Prose mentions must read `>=`, and the strict-`>` literal must be gone.
inc
if grep -qF 'createdAt >= issue.updatedAt' "$RUN_PATH"; then
  pass_msg "run/SKILL.md prose reads 'createdAt >= issue.updatedAt'"
else
  fail_msg "run/SKILL.md prose does not read 'createdAt >= issue.updatedAt'"
fi

inc
if grep -qF 'createdAt >= issue.updatedAt' "$ROUTING_PATH"; then
  pass_msg "dispatch-routing.md prose reads 'createdAt >= issue.updatedAt'"
else
  fail_msg "dispatch-routing.md prose does not read 'createdAt >= issue.updatedAt'"
fi

inc
if grep -qF 'createdAt > issue.updatedAt' "$RUN_PATH"; then
  fail_msg "run/SKILL.md still carries the strict-\`>\` prose literal 'createdAt > issue.updatedAt'"
else
  pass_msg "run/SKILL.md carries no strict-\`>\` prose literal"
fi

inc
if grep -qF 'createdAt > issue.updatedAt' "$ROUTING_PATH"; then
  fail_msg "dispatch-routing.md still carries the strict-\`>\` prose literal 'createdAt > issue.updatedAt'"
else
  pass_msg "dispatch-routing.md carries no strict-\`>\` prose literal"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
