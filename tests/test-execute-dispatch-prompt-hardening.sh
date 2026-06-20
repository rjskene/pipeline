#!/bin/bash
set -uo pipefail

# Regression guard for #764: on the #752 fullsend the inline PATH B execute
# Agent dropped out after narrating *"I'll wait for the suite notification."* —
# it had made the edits + new test but left them UNCOMMITTED (no commit, no
# push, no PR) and the orchestrator had to finish by hand. Root cause is the
# narrate-and-yield failure mode: a dispatched Agent's turn ends the moment it
# stops emitting tool calls, so narrating an intention to wait strands the
# subagent with work in progress.
#
# The binding fix lives at the inline execute DISPATCH site (the Agent prompt
# fullsend/run hands to the subagent) — a `general-purpose`/`tdd-implementer`
# subagent may treat `/pipeline:execute-issue-plan N` as content rather than
# loading skills/execute-issue-plan/SKILL.md, so a dispatch-site terminal-state
# directive — not the skill body — is the binding contract. This mirrors the
# plan-issue dispatch contract guarded by
# tests/test-plan-issue-dispatch-prompt-hardening.sh.
#
# This test asserts both inline execute dispatch sites embed the canonical
# terminal-state directive. The canonical substrings are specific enough to
# catch paraphrasing drift in future edits without being brittle to legitimate
# rewording.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Inline execute dispatch site that MUST carry the terminal-state directive.
# #763: the run→status rename moved ALL inline-execute dispatch wiring out of the
# old /pipeline:run skill into fullsend's Step 6, and DELETED
# skills/run/references/dispatch-routing.md. The read-only /pipeline:status skill
# no longer dispatches, so fullsend is now the single execute dispatch site.
DISPATCH_SITES=(
  "skills/fullsend/SKILL.md"
)

# Canonical directive substrings (must appear at each dispatch site).
CONTRACT_SUBSTRINGS=(
  'valid terminal states are'
  'pr-open'
  'Narrating an intention to "wait"'
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

# 1) Each inline execute dispatch site carries every canonical contract
#    substring.
for site in "${DISPATCH_SITES[@]}"; do
  for needle in "${CONTRACT_SUBSTRINGS[@]}"; do
    assert_contains "execute-dispatch-site" "$site" "$needle"
  done
done

# 2) #1093 split-role phase directives ride the line-299 dispatch-prompt contract.
#    The line-299 binding contract forbids the dispatched
#    `general-purpose`/`tdd-implementer` subagent from loading
#    skills/execute-issue-plan/SKILL.md (it treats `/pipeline:execute-issue-plan N`
#    as content, not a skill load), so the two-phase split-role discipline is NOT
#    inherited from that skill body — it MUST ride the dispatch-site prompt, the
#    same way the #764 terminal-state directive does. Under SPLIT_ROLE=true the
#    RED-author prompt must direct the Opus agent to commit the failing suite with
#    the literal `[split-role-red]` substring in the subject; the contract must be
#    SPLIT_ROLE-aware. These assertions are ADDED alongside (not replacing) the
#    #764 `valid terminal states are` key above — the canonical key is preserved.
#
#    CRITICAL scoping: the directives must live INSIDE the "Inline execute dispatch
#    prompt contract" paragraph itself — NOT merely somewhere in the file (the
#    resolver section + the `--verify-dispatch` block already mention `SPLIT_ROLE`
#    and `[split-role-red]` elsewhere, so a whole-file grep would pass spuriously
#    on the pre-fix prose). Extract the contract paragraph (from its bold header up
#    to the next `   **` sub-heading) and assert co-occurrence WITHIN it.
contract_paragraph() {
  awk '
    /\*\*Inline execute dispatch prompt contract \(mandatory\)\.\*\*/ { inblock = 1; print; next }
    inblock && /^   \*\*/ { inblock = 0 }
    inblock { print }
  ' "$ROOT/skills/fullsend/SKILL.md"
}
contract_flat() { contract_paragraph | tr "\n" " "; }

# 2a) The contract paragraph still anchors on the #764 key (preserved in scope).
inc
if contract_flat | grep -Fq 'valid terminal states are'; then
  pass_msg "split-role-scope: contract paragraph preserves the #764 'valid terminal states are' key"
else
  fail_msg "split-role-scope: contract paragraph lost the #764 'valid terminal states are' key"
fi
# 2b) The contract paragraph is SPLIT_ROLE-aware.
inc
if contract_flat | grep -Fq 'SPLIT_ROLE'; then
  pass_msg "split-role-scope: contract paragraph is SPLIT_ROLE-aware"
else
  fail_msg "split-role-scope: contract paragraph is NOT SPLIT_ROLE-aware (single-shape prompt only)"
fi
# 2c) The RED-author phase directive names the `[split-role-red]` commit anchor
#     WITHIN the contract paragraph.
inc
if contract_flat | grep -Fq '[split-role-red]'; then
  pass_msg "split-role-scope: contract paragraph carries the [split-role-red] RED-author directive"
else
  fail_msg "split-role-scope: contract paragraph missing the [split-role-red] RED-author directive"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
