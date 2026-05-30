#!/bin/bash
set -uo pipefail
# Guard: the run-queue evaluator-terminal emit must be verdict-NEUTRAL and
# carry the gate's block-reason, and the fullsend consumer must match the
# SAME token. Locks producer + consumer together (issue #654). The old
# `approved-manual-merge` token read as an "approved" verdict when the real
# verdict was often `block-verdict` (Flagged for user review).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RQ="$REPO_ROOT/scripts/run-queue.sh"
FS="$REPO_ROOT/skills/fullsend/SKILL.md"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# 1. Producer no longer emits the misleading "approved-manual-merge" token.
inc
if ! grep -q 'outcome="approved-manual-merge"' "$RQ"; then
  pass_msg "producer: legacy approved-manual-merge token removed from run-queue.sh"
else
  fail_msg "producer: run-queue.sh still sets outcome=\"approved-manual-merge\" (misleading; issue #654)"
fi

# 2. Producer sets the verdict-neutral token.
inc
if grep -q 'outcome="manual-merge-required"' "$RQ"; then
  pass_msg "producer: run-queue.sh emits verdict-neutral manual-merge-required token"
else
  fail_msg "producer: run-queue.sh does not set outcome=\"manual-merge-required\""
fi

# 3. Producer EVENT line carries the gate reason= field.
inc
if grep -Eq 'EVENT: agent-finished issue=\$\{issue\} outcome=\$\{outcome\} reason=\$\{_block_reason\} mode=' "$RQ"; then
  pass_msg "producer: EVENT line carries reason=\${_block_reason} alongside outcome"
else
  fail_msg "producer: EVENT line missing reason=\${_block_reason} (gate reason not surfaced)"
fi

# 4. Producer defines the reason extractor wired to the Auto-merge skipped line.
inc
if grep -q 'extract_block_reason()' "$RQ" \
   && grep -q 'Auto-merge skipped: (block-\[a-z-\]+|green)' "$RQ"; then
  pass_msg "producer: extract_block_reason parses the Auto-merge skipped gate token"
else
  fail_msg "producer: extract_block_reason / Auto-merge skipped parse missing"
fi

# 5. Consumer (fullsend) matches the SAME new token, not the old one.
inc
if grep -q 'outcome=manual-merge-required' "$FS" \
   && ! grep -q 'outcome=approved-manual-merge' "$FS"; then
  pass_msg "consumer: fullsend/SKILL.md matches manual-merge-required (old token gone)"
else
  fail_msg "consumer: fullsend/SKILL.md not in lockstep with producer token (issue #654)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
