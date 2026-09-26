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

# 2) #1093 execute phase directives ride the dispatch-prompt contract paragraph,
#    re-pinned by #1420 (split-role lane removed).
#    The binding contract forbids the dispatched
#    `general-purpose`/`tdd-implementer` subagent from loading
#    skills/execute-issue-plan/SKILL.md (it treats `/pipeline:execute-issue-plan N`
#    as content, not a skill load), so the execute discipline is NOT inherited
#    from that skill body — it MUST ride the dispatch-site prompt, the same way
#    the #764 terminal-state directive does. #1420 collapsed PATH B execute to ONE
#    agent, so the contract paragraph must no longer be SPLIT_ROLE-aware and must
#    no longer prescribe a `[split-role-red]` anchor commit: those assertions
#    invert into negatives here. The #764 `valid terminal states are` key is
#    preserved.
#
#    CRITICAL scoping: the assertions are scoped to the "Inline execute dispatch
#    prompt contract" paragraph itself — NOT merely somewhere in the file (a
#    whole-file grep would pass spuriously on prose living in the resolver section
#    or the routing reference). Extract the contract paragraph (from its bold
#    header up to the next `   **` sub-heading) and assert WITHIN it.
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
# 2b) The contract paragraph is NOT SPLIT_ROLE-aware (#1420): there is no split
#     shape left for it to branch on.
inc
if contract_flat | grep -Fq 'SPLIT_ROLE'; then
  fail_msg "single-shape: contract paragraph still mentions SPLIT_ROLE (#1420 removed the split-role lane)"
else
  pass_msg "single-shape: contract paragraph carries no SPLIT_ROLE branch"
fi
# 2c) The contract paragraph no longer prescribes the `[split-role-red]` anchor
#     commit (#1420): one execute agent commits per red-green cycle, so there is
#     no locked-suite marker commit to demand.
inc
if contract_flat | grep -Fq '[split-role-red]'; then
  fail_msg "single-shape: contract paragraph still carries the [split-role-red] RED-author directive (#1420 removed the anchor commit)"
else
  pass_msg "single-shape: contract paragraph carries no [split-role-red] directive"
fi

# 2d) #1122 worktree-index staging precondition. The #615/#617 leak: a split-role
#     execute subagent's `git add` hit the MAIN checkout index instead of its own
#     worktree index, leaving staged edits that aborted the inter-leg
#     `git pull --ff-only`. The #1106 git-anchoring sentence pins `git -C` for
#     commit + branch-assert but has NO positive precondition that `git add` stages
#     into the WORKTREE index. Assert the contract paragraph now carries a
#     worktree-index staging precondition (stable substring `worktree index`),
#     scoped to the extracted paragraph — a whole-file grep would pass spuriously
#     because `--verify-dispatch`/resolver prose elsewhere may mention worktrees.
inc
if contract_flat | grep -Fq 'worktree index'; then
  pass_msg "split-role-scope: contract paragraph carries the #1122 worktree-index staging precondition"
else
  fail_msg "split-role-scope: contract paragraph missing the #1122 worktree-index staging precondition ('worktree index')"
fi

# 2e) #1387 closing-review directive. A dispatched `general-purpose` subagent
#     NEVER loads skills/execute-issue-plan/SKILL.md, so Step 8's closing
#     independent code review happens only if the DISPATCH SITE asks for it.
#     The split-role prompt carried the red/green, git-anchoring, staging, suite
#     and cross-cutting-guard directives but said NOTHING about the closing
#     review, so cycle 16's PATH B issue produced no review-role cost row at all
#     — the row the cycle-15 work exists to create.
#
#     Same CRITICAL scoping as 2b–2d: assert INSIDE the extracted contract
#     paragraph, not the whole file — skills/execute-issue-plan/SKILL.md and the
#     PATH C routing bullet already name `code review #<N>`, so a whole-file
#     grep would pass spuriously on the pre-fix prose.
#
#     The description is FIXED (`code review #<N>`, append nothing): the cost
#     parser resolves exactly that shape to stage=pr-eval / role=review, which is
#     what makes the review's cost land on the issue's row.
inc
if contract_flat | grep -Fq 'code review #<N>'; then
  pass_msg "closing-review: contract paragraph carries the fixed 'code review #<N>' dispatch description"
else
  fail_msg "closing-review: contract paragraph missing the 'code review #<N>' dispatch description"
fi

# 2f) The closing-review directive must bind the ONE execute agent (#1420). Before
#     #1420 it had to name both the split-role `green-implementer` and the
#     single-role lane; with the lane gone there is exactly one execute agent to
#     bind, and naming the retired green role would leave the contract describing
#     a dispatch shape that no longer exists.
inc
if contract_flat | grep -Fq 'the execute agent' \
   && ! contract_flat | grep -Fq 'green-implementer'; then
  pass_msg "closing-review: directive binds 'the execute agent' and no longer names the retired green-implementer"
else
  fail_msg "closing-review: directive must bind 'the execute agent' and must NOT name 'green-implementer' (#1420)"
fi

# 2g) PATH D exclusion marker. skills/execute-issue-plan/SKILL.md Step 8
#     early-returns for `quick-fix`, so the closing review does NOT apply to
#     PATH D; without the carve-out the dispatch-site directive contradicts the
#     skill's own early-return contract.
inc
if contract_flat | grep -Fq 'PATH D'; then
  pass_msg "closing-review: contract paragraph carries the PATH D exclusion marker"
else
  fail_msg "closing-review: contract paragraph missing the PATH D exclusion marker (execute-issue-plan Step 8 early-returns for quick-fix)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
