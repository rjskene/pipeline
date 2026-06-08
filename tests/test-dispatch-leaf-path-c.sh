#!/bin/bash
set -euo pipefail

# Acceptance test for the PATH C branch of scripts/dispatch-leaf.sh (issue #983).
#
# dispatch-leaf.sh `dispatch` wraps the UNCHANGED path-c-split-worktree.sh
# setup -> (per-leaf dispatch) -> reassemble -> teardown lifecycle. The contract
# is: ONLY the per-leaf dispatch VERB branches on $PIPELINE_HARNESS; the
# harness-INVARIANT lifecycle phases (setup / reassemble / teardown) that delegate
# to path-c-split-worktree.sh must be IDENTICAL on both harnesses.
#
# This test renders the dispatch PLAN (PIPELINE_DISPATCH_DRY_RUN=1) for both
# harnesses against a REAL parent git worktree (modelled on
# tests/test-path-c-split-worktree.sh) and asserts:
#   1. the setup/reassemble/teardown lines are byte-for-byte identical across
#      claude and codex -> path-c-split-worktree.sh's contract is preserved;
#   2. ONLY the dispatch verb between setup and reassemble differs (claude uses
#      the in-session Agent tool; codex uses spawn_agent/wait_agent/close_agent);
#   3. each leaf's setup line names the UNCHANGED helper with the leaf id.
#
# No leaves are actually dispatched and no Agent/spawn_agent is issued — the seam
# is the BRANCH, asserted via the emitted plan. mktemp -d + trap-rm, no network.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve to the SAME canonical absolute paths dispatch-leaf.sh prints — it roots
# the helper path at `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd`, so a
# "$SCRIPT_DIR/../scripts/..." literal would NOT byte-match the emitted line.
RESOLVED_SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
DISPATCH="$RESOLVED_SCRIPTS/dispatch-leaf.sh"
SPLIT="$RESOLVED_SCRIPTS/path-c-split-worktree.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

for f in "$DISPATCH" "$SPLIT"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required script missing at $f" >&2
    exit 1
  fi
done

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# --- build a real parent repo on branch feature/parent (modelled on
#     test-path-c-split-worktree.sh) so dispatch-leaf can absolutize PARENT and
#     the plan names a real worktree path. ---
REPO="$WORKDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
git -C "$REPO" checkout -q -b feature/parent
echo base > "$REPO/base.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "base"

LEAF1="dev/probe/a/"
LEAF2="dev/probe/b/"

# Render the dispatch plan for a given harness (dry-run; no dispatch executed).
plan_for() {
  local harness="$1"
  PIPELINE_HARNESS="$harness" PIPELINE_DISPATCH_DRY_RUN=1 \
    bash "$DISPATCH" dispatch "$REPO" "$LEAF1" "$LEAF2"
}

PLAN_CLAUDE=$(plan_for claude)
PLAN_CODEX=$(plan_for codex)

# Extract only the harness-INVARIANT lifecycle lines (setup/reassemble/teardown);
# these delegate to path-c-split-worktree.sh and must not vary by harness.
lifecycle_lines() {
  printf '%s\n' "$1" | grep -E '^(setup|reassemble|teardown):'
}
LIFE_CLAUDE=$(lifecycle_lines "$PLAN_CLAUDE")
LIFE_CODEX=$(lifecycle_lines "$PLAN_CODEX")

# Extract only the per-leaf dispatch/reap verb lines; these are the ONLY part
# that is allowed to branch on harness.
dispatch_lines() {
  printf '%s\n' "$1" | grep -E '^(dispatch|reap)\['
}
DISP_CLAUDE=$(dispatch_lines "$PLAN_CLAUDE")
DISP_CODEX=$(dispatch_lines "$PLAN_CODEX")

# -------------------------------------------------------------------------
# Test 1: setup/reassemble/teardown lines are byte-for-byte identical across
#         both harnesses -> path-c-split-worktree.sh's contract is preserved.
# -------------------------------------------------------------------------
echo "Test 1: lifecycle (setup/reassemble/teardown) identical on both harnesses"
inc
if [ -n "$LIFE_CLAUDE" ] && [ "$LIFE_CLAUDE" = "$LIFE_CODEX" ]; then
  pass_msg "split-worktree lifecycle lines are harness-invariant"
else
  fail_msg "lifecycle lines diverge between claude and codex"
  echo "  --- claude lifecycle ---"; printf '%s\n' "$LIFE_CLAUDE" | sed 's/^/    /'
  echo "  --- codex lifecycle ---";  printf '%s\n' "$LIFE_CODEX"  | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 2: the lifecycle lines invoke the UNCHANGED helper for setup (per leaf),
#         reassemble (all leaves) and teardown (all leaves).
# -------------------------------------------------------------------------
echo "Test 2: lifecycle lines delegate to the UNCHANGED path-c-split-worktree.sh"
inc
PARENT_ABS=$(cd "$REPO" && pwd)
ok=1
echo "$LIFE_CLAUDE" | grep -qF "setup: bash $SPLIT setup $PARENT_ABS $LEAF1" || { fail_msg "missing setup line for leaf 1"; ok=0; }
if [ "$ok" = "1" ]; then echo "$LIFE_CLAUDE" | grep -qF "setup: bash $SPLIT setup $PARENT_ABS $LEAF2" || { fail_msg "missing setup line for leaf 2"; ok=0; }; fi
if [ "$ok" = "1" ]; then echo "$LIFE_CLAUDE" | grep -qF "reassemble: bash $SPLIT reassemble $PARENT_ABS $LEAF1 $LEAF2" || { fail_msg "missing reassemble line"; ok=0; }; fi
if [ "$ok" = "1" ]; then echo "$LIFE_CLAUDE" | grep -qF "teardown: bash $SPLIT teardown $PARENT_ABS $LEAF1 $LEAF2" || { fail_msg "missing teardown line"; ok=0; }; fi
[ "$ok" = "1" ] && pass_msg "setup(per-leaf) + reassemble + teardown all name the unchanged helper"

# -------------------------------------------------------------------------
# Test 3: the dispatch verb DOES differ between harnesses (that is the seam).
# -------------------------------------------------------------------------
echo "Test 3: ONLY the dispatch verb differs between harnesses"
inc
if [ -n "$DISP_CLAUDE" ] && [ -n "$DISP_CODEX" ] && [ "$DISP_CLAUDE" != "$DISP_CODEX" ]; then
  pass_msg "claude vs codex dispatch verbs differ (the harness seam)"
else
  fail_msg "dispatch verbs did not differ across harnesses"
  echo "  --- claude dispatch ---"; printf '%s\n' "$DISP_CLAUDE" | sed 's/^/    /'
  echo "  --- codex dispatch ---";  printf '%s\n' "$DISP_CODEX"  | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 4: claude dispatch uses the in-session Agent tool; codex dispatch uses
#         the spawn_agent/wait_agent/close_agent agent-control verbs.
# -------------------------------------------------------------------------
echo "Test 4: harness-specific dispatch verbs are the expected control surfaces"
inc
ok=1
echo "$DISP_CLAUDE" | grep -qF "Agent(subagent_type=tdd-implementer, leaf=$LEAF1)" || { fail_msg "claude leaf-1 dispatch is not the Agent tool"; ok=0; }
if [ "$ok" = "1" ]; then echo "$DISP_CLAUDE" | grep -qF "Agent(subagent_type=tdd-implementer, leaf=$LEAF2)" || { fail_msg "claude leaf-2 dispatch is not the Agent tool"; ok=0; }; fi
if [ "$ok" = "1" ]; then echo "$DISP_CODEX" | grep -qF "spawn_agent leaf=$LEAF1" || { fail_msg "codex leaf-1 dispatch is not spawn_agent"; ok=0; }; fi
if [ "$ok" = "1" ]; then echo "$DISP_CODEX" | grep -qF "wait_agent leaf=$LEAF1" || { fail_msg "codex leaf-1 reap missing wait_agent"; ok=0; }; fi
if [ "$ok" = "1" ]; then echo "$DISP_CODEX" | grep -qF "close_agent leaf=$LEAF1" || { fail_msg "codex leaf-1 reap missing close_agent"; ok=0; }; fi
if [ "$ok" = "1" ]; then
  # codex must NOT use the in-session Agent tool, and claude must NOT use spawn_agent.
  echo "$DISP_CODEX" | grep -q "Agent(subagent_type" && { fail_msg "codex plan wrongly uses the in-session Agent tool"; ok=0; }
fi
if [ "$ok" = "1" ]; then
  echo "$DISP_CLAUDE" | grep -q "spawn_agent" && { fail_msg "claude plan wrongly uses spawn_agent"; ok=0; }
fi
[ "$ok" = "1" ] && pass_msg "claude=Agent tool, codex=spawn_agent/wait_agent/close_agent"

# -------------------------------------------------------------------------
# Test 5: the per-leaf dispatch verb is bracketed by setup-before and
#         reassemble-after in BOTH plans (lifecycle ordering preserved).
# -------------------------------------------------------------------------
echo "Test 5: dispatch verb sits between setup and reassemble in both plans"
inc
ordering_ok() {
  local plan="$1"
  local n_setup n_dispatch n_reassemble
  # line numbers of the first setup, first dispatch[, and the reassemble line
  n_setup=$(printf '%s\n' "$plan" | grep -nE '^setup:' | head -1 | cut -d: -f1)
  n_dispatch=$(printf '%s\n' "$plan" | grep -nE '^dispatch\[' | head -1 | cut -d: -f1)
  n_reassemble=$(printf '%s\n' "$plan" | grep -nE '^reassemble:' | head -1 | cut -d: -f1)
  [ -n "$n_setup" ] && [ -n "$n_dispatch" ] && [ -n "$n_reassemble" ] || return 1
  [ "$n_setup" -lt "$n_dispatch" ] && [ "$n_dispatch" -lt "$n_reassemble" ]
}
if ordering_ok "$PLAN_CLAUDE" && ordering_ok "$PLAN_CODEX"; then
  pass_msg "setup < dispatch < reassemble holds for both harnesses"
else
  fail_msg "lifecycle ordering setup<dispatch<reassemble violated"
  echo "  --- claude plan ---"; printf '%s\n' "$PLAN_CLAUDE" | sed 's/^/    /'
  echo "  --- codex plan ---";  printf '%s\n' "$PLAN_CODEX"  | sed 's/^/    /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
