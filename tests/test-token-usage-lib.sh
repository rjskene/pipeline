#!/usr/bin/env bash
# Test: scripts/_token-usage-lib.sh
#   - tu_transcript_sum: correct token sums, ts range, last non-empty model
#   - tu_worktree_slug: DOUBLE-dash slug (.claude -> --claude) Finding-1 guard
#   - tu_stage_from_description / tu_issue_from_description: real-vocab cases
set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/_token-usage-lib.sh"
FIX="$THIS_DIR/fixtures/token-usage"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$LIB" ] || fail "library not found: $LIB"
# shellcheck source=/dev/null
source "$LIB"

# ---------------------------------------------------------------------------
# tu_transcript_sum
# ---------------------------------------------------------------------------
got="$(tu_transcript_sum "$FIX/transcript.jsonl")"
want=$'350\t70\t16\t5\t2026-05-30T10:00:00.000Z\t2026-05-30T10:00:09.000Z\tclaude-opus-4-8'
[ "$got" = "$want" ] || fail "tu_transcript_sum: got [$got] want [$want]"
pass "tu_transcript_sum sums + ts-range + last non-empty model"

# ---------------------------------------------------------------------------
# tu_worktree_slug  (Finding-1: .claude -> --claude DOUBLE dash)
# ---------------------------------------------------------------------------
in="/home/rjskene/claude-pipeline/.claude/worktrees/wt-68-68-plugin-manifest-scaffolding"
want_slug="-home-rjskene-claude-pipeline--claude-worktrees-wt-68-68-plugin-manifest-scaffolding"
got_slug="$(tu_worktree_slug "$in")"
[ "$got_slug" = "$want_slug" ] || fail "tu_worktree_slug: got [$got_slug] want [$want_slug]"
case "$got_slug" in
  *--claude-*) pass "tu_worktree_slug produces DOUBLE-dash .claude form" ;;
  *) fail "tu_worktree_slug missing DOUBLE dash (.claude not sanitized): [$got_slug]" ;;
esac

# ---------------------------------------------------------------------------
# tu_stage_from_description  (precedence-ordered free-text normaliser)
# ---------------------------------------------------------------------------
check_stage() {
  local desc="$1" want="$2"
  local got; got="$(tu_stage_from_description "$desc")"
  [ "$got" = "$want" ] || fail "stage [$desc]: got [$got] want [$want]"
  pass "stage [$desc] -> [$want]"
}

check_stage "Classify #310" "classify"
check_stage "Plan #310" "plan"
check_stage "Re-plan #310" "plan"
check_stage "execute-issue-plan #310" "execute"
check_stage "Execute #310" "execute"
check_stage "Evaluate plan #310" "plan-eval"
check_stage "Evaluate plan for #134" "plan-eval"
check_stage "Re-evaluate plan #134" "plan-eval"
check_stage "Evaluate PR #137 for #134" "pr-eval"
check_stage "evaluate-issue-pr #626 / PR #637" "pr-eval"
check_stage "Classify + plan + evaluate #777" "classify"
check_stage "analyze open-issue hygiene shortlist" ""

# ---------------------------------------------------------------------------
# tu_issue_from_description  (real enumerated shapes)
# ---------------------------------------------------------------------------
check_issue() {
  local desc="$1" want="$2"
  local got; got="$(tu_issue_from_description "$desc")"
  [ "$got" = "$want" ] || fail "issue [$desc]: got [$got] want [$want]"
  pass "issue [$desc] -> [$want]"
}

check_issue "Classify #310" "310"
check_issue "Evaluate PR #137 for #134" "134"
check_issue "evaluate-issue-pr #626 / PR #637" "626"
check_issue "Evaluate PR #363 (#361)" "361"
check_issue "Evaluate PR #384 (issue #342)" "342"
check_issue "eval-pr #592 (PR #603)" "592"
check_issue "Classify + plan + evaluate #777" "777"

echo "all tests passed"
