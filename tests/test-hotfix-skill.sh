#!/bin/bash
set -euo pipefail
# Contract guard: skills/hotfix/SKILL.md must document the locked emergency-lane
# design decisions: in-session execution (no spawn-claude/tmux), hybrid
# --inline/--subagent executor with subagent default, trap-based cwd
# restoration on EXIT/ERR/INT, lifecycle-bypass invariants (no pipeline
# labels applied, no evaluate-issue-plan/evaluate-issue-pr invocation), PR
# targets PIPELINE_BASE_BRANCH, PATH-D boundary callout, and the
# restrict_paths.py / issue #353 safety notes.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/hotfix/SKILL.md"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

assert_contains() {
  local needle="$1"; local label="$2"
  inc
  if grep -qF -- "$needle" "$SKILL"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

assert_not_contains() {
  local needle="$1"; local label="$2"
  inc
  if grep -qF -- "$needle" "$SKILL"; then
    fail_msg "$label (unexpected substring present: $needle)"
  else
    pass_msg "$label"
  fi
}

# Precise label-apply assertion — fails if the skill body INVOKES
# `gh issue edit ... --add-label <label>` (label names may appear in prose
# describing the bypass without triggering this).
assert_no_label_apply() {
  local label="$1"
  inc
  if grep -qE -- "--add-label[[:space:]=]+['\"]?${label}['\"]?" "$SKILL"; then
    fail_msg "skill body does NOT add-label ${label} (unexpected --add-label ${label} present)"
  else
    pass_msg "skill body does NOT add-label ${label}"
  fi
}

echo "Hotfix skill contract"

# Existence.
inc
if [ -f "$SKILL" ]; then
  pass_msg "skills/hotfix/SKILL.md exists"
else
  fail_msg "skills/hotfix/SKILL.md exists"
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

# In-session execution.
assert_contains "in-session"            "documents in-session execution"
assert_contains "current orchestrator"  "states orchestrator session is the runtime"
assert_not_contains "spawn-claude"      "does NOT invoke spawn-claude (in-session only)"
assert_not_contains "tmux"              "does NOT reference tmux"

# Hybrid executor flags.
assert_contains "--inline"              "documents --inline flag"
assert_contains "--subagent"            "documents --subagent flag"
# Default executor: substring "default" must co-occur with "subagent" (combined check).
inc
if grep -qE -- "(default[^a-zA-Z]+[^[:space:]]*\s*--?subagent|--?subagent[^a-zA-Z]+[^[:space:]]*\s*default|default[^.]*subagent)" "$SKILL"; then
  pass_msg "default executor is --subagent"
else
  fail_msg "default executor is --subagent (no 'default ... subagent' co-occurrence found)"
fi

# Trap-based cwd restoration.
assert_contains "trap"                  "documents trap-based cwd restore"
assert_contains "EXIT"                  "trap fires on EXIT"
assert_contains "ERR"                   "trap fires on ERR"
assert_contains "INT"                   "trap fires on INT"

# Lifecycle bypass — prose mention.
assert_contains "no pipeline labels"    "asserts no pipeline labels applied"

# Lifecycle bypass — verified absence of label-apply invocations.
assert_no_label_apply "plan-pending"
assert_no_label_apply "plan-reviewed"
assert_no_label_apply "plan-approved"
assert_no_label_apply "in-progress"
assert_no_label_apply "pr-open"

# Evaluator bypass.
assert_contains "no /pipeline:evaluate-issue-plan" "skips evaluate-issue-plan"
assert_contains "no /pipeline:evaluate-issue-pr"   "skips evaluate-issue-pr"
assert_contains "no auto-merge"                    "asserts no auto-merge gate fires"

# PR base.
assert_contains "PIPELINE_BASE_BRANCH"  "PR targets configured base branch"

# PATH-D boundary callout.
assert_contains "PATH D"                "documents PATH D boundary"

# Path-safety / restrict_paths.py history.
assert_contains "issue #353"            "calls out restrict_paths.py hook-bug family"
assert_contains "restrict_paths.py"     "references the restrict_paths.py hook by name"

# Worktree helper reuse.
assert_contains "setup-worktree.sh"     "reuses existing worktree helper"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
