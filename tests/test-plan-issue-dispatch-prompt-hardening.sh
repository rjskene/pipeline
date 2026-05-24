#!/bin/bash
set -uo pipefail

# Regression guard for #456: the plan-issue subagent returned the plan body in
# chat and skipped the `gh issue comment` + `plan-pending` label-add side-effects.
# Root cause is dispatch-boundary leakage — a `general-purpose` subagent
# dispatched by fullsend/run may not load skills/plan-issue/SKILL.md at all; it
# treats `/pipeline:plan-issue N` as a content-instruction. The binding fix lives
# at the dispatch site (the Agent prompt fullsend/run hands to the subagent).
#
# This test asserts both dispatch sites embed the canonical "Dispatch prompt
# contract" directive, and that plan-issue documents the caller contract for
# defense-in-depth. The three canonical substrings are specific enough to catch
# paraphrasing drift in future edits without being brittle to legitimate
# rewording.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Dispatch sites that MUST carry the verbatim contract directive.
DISPATCH_SITES=(
  "skills/fullsend/SKILL.md"
  "skills/run/references/dispatch-routing.md"
)

# Canonical directive substrings (must appear at each dispatch site).
CONTRACT_SUBSTRINGS=(
  'post-plan.sh'
  'MUST end with'
  'plan body in chat is a failure'
)

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# Assert a file contains a literal substring.
assert_contains() {
  local label="$1" file="$2" needle="$3"
  inc
  if [ ! -f "$ROOT/$file" ]; then
    fail_msg "$label: $file not found"
    return
  fi
  if grep -F -q "$needle" "$ROOT/$file"; then
    pass_msg "$label: $file contains \"$needle\""
  else
    fail_msg "$label: $file missing \"$needle\""
  fi
}

# 1) Each dispatch site carries every canonical contract substring.
for site in "${DISPATCH_SITES[@]}"; do
  for needle in "${CONTRACT_SUBSTRINGS[@]}"; do
    assert_contains "dispatch-site" "$site" "$needle"
  done
done

# 2) plan-issue documents the caller contract (defense-in-depth) and names both
#    call sites so a future caller refactor cannot silently drop the directive.
assert_contains "caller-contract" "skills/plan-issue/SKILL.md" "Caller contract"
assert_contains "caller-contract" "skills/plan-issue/SKILL.md" "fullsend"
assert_contains "caller-contract" "skills/plan-issue/SKILL.md" "run"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
