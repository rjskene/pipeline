#!/bin/bash
set -uo pipefail

# Regression guard for #772: on the #765 fullsend the inline PATH-B
# evaluate-issue-pr Agent did all its verification, then ended its turn with
# *"...All plan items verified. Awaiting the suite/CI output."* — it narrated an
# intention to wait and yielded instead of running to terminal state. No
# `## Evaluation` verdict was posted, the greenlight gate never fired, and the
# issue was stranded at `pr-open`; the orchestrator had to re-dispatch a fresh
# evaluator (~30k tokens wasted). Same narrate-and-yield drop-out #764 fixed for
# the inline EXECUTE dispatch — but #764/#771 hardened only the execute sites.
#
# The binding fix lives at the inline PR-eval DISPATCH site (the Agent prompt
# fullsend/run hands to the subagent) — a `general-purpose` subagent may treat
# `/pipeline:evaluate-issue-pr N` (or "follow skills/evaluate-issue-pr/SKILL.md")
# as content rather than loading the skill, so a dispatch-site terminal-state
# directive — not the skill body — is the binding contract. This mirrors the
# execute contract guarded by tests/test-execute-dispatch-prompt-hardening.sh.
#
# This test asserts both inline PR-eval dispatch sites embed the canonical
# eval terminal-state directive. The canonical substrings are specific enough to
# catch paraphrasing drift in future edits without being brittle to legitimate
# rewording.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Inline evaluate-issue-pr dispatch sites that MUST carry the terminal-state
# directive (mirror of the execute two-site parity).
DISPATCH_SITES=(
  "skills/fullsend/SKILL.md"
  "skills/run/SKILL.md"
)

# Canonical directive substrings (must appear at each dispatch site).
CONTRACT_SUBSTRINGS=(
  'valid terminal states are'
  '## Evaluation'
  '**Verdict:**'
  'greenlight gate'
  'block-'
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

# 1) Each inline PR-eval dispatch site carries every canonical contract
#    substring.
for site in "${DISPATCH_SITES[@]}"; do
  for needle in "${CONTRACT_SUBSTRINGS[@]}"; do
    assert_contains "preval-dispatch-site" "$site" "$needle"
  done
done

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
