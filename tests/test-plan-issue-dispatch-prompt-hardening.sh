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
# #763: the run→status rename DELETED skills/run/references/dispatch-routing.md
# (its plan-issue dispatch-prompt contract relocated into fullsend's Step 1b).
# fullsend is now the single dispatch site for the plan-issue contract.
DISPATCH_SITES=(
  "skills/fullsend/SKILL.md"
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

# Print the body of a `## <heading>` section: lines after the heading up to the
# next heading line (anything starting with `#`). Used so cross-reference
# assertions are scoped to the section, not satisfied by an unrelated mention
# elsewhere in the file.
section_body() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    $0 == h { f = 1; next }
    f && /^#/ { f = 0 }
    f { print }
  ' "$ROOT/$file"
}

# Assert a named section of a file contains a literal substring.
assert_section_contains() {
  local label="$1" file="$2" heading="$3" needle="$4"
  inc
  if [ ! -f "$ROOT/$file" ]; then
    fail_msg "$label: $file not found"
    return
  fi
  if section_body "$file" "$heading" | grep -F -q "$needle"; then
    pass_msg "$label: $file [$heading] contains \"$needle\""
  else
    fail_msg "$label: $file [$heading] missing \"$needle\""
  fi
}

# 1) Each dispatch site carries every canonical contract substring.
for site in "${DISPATCH_SITES[@]}"; do
  for needle in "${CONTRACT_SUBSTRINGS[@]}"; do
    assert_contains "dispatch-site" "$site" "$needle"
  done
done

# 2) plan-issue documents the caller contract (defense-in-depth). The
#    cross-reference checks are scoped to the `## Caller contract` section
#    (not the whole file) and use the specific `/pipeline:<cmd>` tokens, so a
#    future edit that drops either call-site reference from the section is
#    actually caught — a bare file-wide grep for "run"/"fullsend" would pass
#    regardless and give false confidence.
assert_contains "caller-contract" "skills/plan-issue/SKILL.md" "## Caller contract"
assert_section_contains "caller-contract" "skills/plan-issue/SKILL.md" "## Caller contract" "/pipeline:fullsend"
# The "/pipeline:run" caller-contract cross-reference was DROPPED for #763: Task 1
# narrowed plan-issue's Caller contract to name only /pipeline:fullsend as the
# dispatching caller (the read-only /pipeline:status and its /pipeline:run alias
# no longer dispatch plan-issue). Verified: plan-issue's `## Caller contract`
# section references only /pipeline:fullsend.

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
