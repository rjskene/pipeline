#!/usr/bin/env bash
# Test: the pre-PR verification SKILL prose wires in the cross-cutting-guards
# aggregator (scripts/check-cross-cutting-guards.sh) across the three stages that
# perform pre-PR / pre-greenlight verification (#1132).
#
# Mirror of tests/test-execute-issue-plan-config-drift-step9.sh.
#
# The aggregator is the FAST always-run floor that catches diff-independent
# repo invariants even when only an affected-tests subset was verified. Each
# stage that can open/merge a PR must invoke it so a dispatched subagent that
# never loads the skill body still runs it (defense-in-depth).
#
# Asserts:
#  (a) skills/execute-issue-plan/SKILL.md references 'check-cross-cutting-guards.sh'
#      inside Step 9 (the Open a pull request block).
#  (b) skills/execute-issue-plan/SKILL.md carries an ALWAYS-RUN note: the
#      cross-cutting guards subset runs pre-PR even when only an affected-tests
#      subset was verified.
#  (c) skills/evaluate-issue-pr/SKILL.md references 'check-cross-cutting-guards.sh'
#      (Phase-2 pre-greenlight path — runs even on the #957 green-CI short-circuit).
#  (d) skills/fullsend/SKILL.md references 'check-cross-cutting-guards.sh' in its
#      dispatch-site verification directives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

EXECUTE_SKILL="$ROOT/skills/execute-issue-plan/SKILL.md"
PREVAL_SKILL="$ROOT/skills/evaluate-issue-pr/SKILL.md"
FULLSEND_SKILL="$ROOT/skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$EXECUTE_SKILL" "$PREVAL_SKILL" "$FULLSEND_SKILL"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required SKILL.md not found: $f" >&2
    exit 1
  fi
done

REF="check-cross-cutting-guards.sh"

# --- (a) execute-issue-plan Step 9 references the aggregator ---
#
# Extract Step 9 region: from "9. **Open a pull request" up to (but not
# including) "10. **Mark as pr-open" (same window as the config-drift mirror).
inc
STEP9="$(awk '/^9\. \*\*Open a pull request/{f=1} /^10\. \*\*Mark as pr-open/{f=0} f' "$EXECUTE_SKILL")"
if [ -z "$STEP9" ]; then
  fail_msg "could not extract Step 9 region from execute-issue-plan/SKILL.md"
elif printf '%s\n' "$STEP9" | grep -qF "$REF"; then
  pass_msg "execute-issue-plan Step 9 references $REF"
else
  fail_msg "execute-issue-plan Step 9 does NOT reference $REF"
fi

# --- (b) execute-issue-plan has the ALWAYS-RUN note ---
#
# Accept the note anywhere in the skill body: it must tie the cross-cutting
# guards to running pre-PR even when only an affected-tests subset was verified.
# Match a line that mentions the aggregator/cross-cutting guards AND an
# always-run qualifier (always-run / always run / even when).
inc
if grep -niE 'cross-cutting' "$EXECUTE_SKILL" | grep -qiE 'always[- ]run|always|even when|regardless'; then
  pass_msg "execute-issue-plan carries the cross-cutting always-run note"
elif grep -iE 'always[- ]run|even when only|regardless of' "$EXECUTE_SKILL" | grep -qiF "$REF"; then
  pass_msg "execute-issue-plan carries the cross-cutting always-run note"
else
  fail_msg "execute-issue-plan missing always-run note for the cross-cutting guards subset"
fi

# --- (c) evaluate-issue-pr references the aggregator ---
inc
if grep -qF "$REF" "$PREVAL_SKILL"; then
  pass_msg "evaluate-issue-pr references $REF"
else
  fail_msg "evaluate-issue-pr does NOT reference $REF (Phase-2 pre-greenlight wiring missing)"
fi

# --- (d) fullsend dispatch directives reference the aggregator ---
inc
if grep -qF "$REF" "$FULLSEND_SKILL"; then
  pass_msg "fullsend dispatch directives reference $REF"
else
  fail_msg "fullsend does NOT reference $REF in its dispatch-site verification directives"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
