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

# Inline execute dispatch sites that MUST carry the terminal-state directive.
# dispatch-routing.md mirrors the run/SKILL.md Step 6 directive verbatim — the
# same two-site parity the plan-issue contract has across fullsend/SKILL.md and
# dispatch-routing.md (#771, follow-up to #764).
DISPATCH_SITES=(
  "skills/fullsend/SKILL.md"
  "skills/run/SKILL.md"
  "skills/run/references/dispatch-routing.md"
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

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
