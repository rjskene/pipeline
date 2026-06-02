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
#   (c) the freshness prose mention reads `createdAt >= issue.updatedAt`, and
#       does not still carry the strict-`>` literal
#
# #763 repoint: the run→status rename moved ALL classify/plan dispatch wiring
# (including this freshness-check prose) out of the read-only /pipeline:status
# skill into skills/fullsend/SKILL.md, and DELETED skills/run/references/
# dispatch-routing.md entirely. So the single surviving prose home for the
# `createdAt >= issue.updatedAt` mention is fullsend's Step 1b. The classify-issue
# OR-equality asserts (a)/(b) are unchanged.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLASSIFY_PATH="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"
FULLSEND_PATH="$SCRIPT_DIR/../skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$CLASSIFY_PATH" "$FULLSEND_PATH"; do
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

# (c) The fullsend prose mention must read `>=`, and the strict-`>` literal
#     must be gone. (The deleted dispatch-routing.md asserts were dropped — that
#     reference file no longer exists; fullsend Step 1b is its only successor.)
inc
if grep -qF 'createdAt >= issue.updatedAt' "$FULLSEND_PATH"; then
  pass_msg "fullsend/SKILL.md prose reads 'createdAt >= issue.updatedAt'"
else
  fail_msg "fullsend/SKILL.md prose does not read 'createdAt >= issue.updatedAt'"
fi

inc
if grep -qF 'createdAt > issue.updatedAt' "$FULLSEND_PATH"; then
  fail_msg "fullsend/SKILL.md still carries the strict-\`>\` prose literal 'createdAt > issue.updatedAt'"
else
  pass_msg "fullsend/SKILL.md carries no strict-\`>\` prose literal"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
