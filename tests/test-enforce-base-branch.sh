#!/bin/bash
set -euo pipefail

# Tests for hooks/enforce-base-branch.py covering the two match arms:
#   - `gh pr create`: missing --base is FATAL (preserves long-standing
#     defense-in-depth against GitHub's default-branch fallback).
#   - `gh pr edit`:   missing --base is ALLOWED (title/body-only edits
#     must not be blocked); --base <mismatch> is BLOCKED.
#
# Drives the hook by piping a PreToolUse Bash event JSON on stdin and
# inspecting the exit code (and, for blocks, stderr).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/enforce-base-branch.py"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HOOK" ]; then
  echo "ERROR: hook not found at $HOOK" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Configure a project dir whose resolved EXPECTED_BASE is "staging".
PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude"
printf 'staging\n' > "$PROJ/.claude/base-branch"
printf 'PIPELINE_BASE_BRANCH="staging"\n' > "$PROJ/pipeline.config"

run_hook() {
  local command="$1"
  # Build the JSON via python to safely escape the command string.
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$command")
  set +e
  echo "$payload" | env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$PROJ" \
    python3 "$HOOK" >"$WORKDIR/out" 2>"$WORKDIR/err"
  local rc=$?
  set -e
  echo "$rc"
}

# --- Case A: gh pr create --base staging -> allow ---
echo "Case A: gh pr create --base staging allows"
inc
rc=$(run_hook 'gh pr create --base staging --title T --body B')
if [ "$rc" = "0" ]; then
  pass_msg "Case A: allowed"
else
  fail_msg "Case A: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

# --- Case B: gh pr create --base main -> block ---
echo "Case B: gh pr create --base main blocks"
inc
rc=$(run_hook 'gh pr create --base main --title T --body B')
if [ "$rc" != "0" ]; then
  pass_msg "Case B: blocked"
else
  fail_msg "Case B: expected rc!=0, got rc=$rc"
fi

# --- Case C: gh pr create (no --base) -> block (FATAL for create) ---
echo "Case C: gh pr create without --base blocks (fatal)"
inc
rc=$(run_hook 'gh pr create --title T --body B')
if [ "$rc" != "0" ]; then
  pass_msg "Case C: blocked (preserves fatal-missing-base semantics for create)"
else
  fail_msg "Case C: expected rc!=0, got rc=$rc"
fi

# --- Case D: gh pr edit 1 --base main -> block ---
echo "Case D: gh pr edit --base main blocks"
inc
rc=$(run_hook 'gh pr edit 1 --base main')
if [ "$rc" != "0" ]; then
  pass_msg "Case D: blocked"
else
  fail_msg "Case D: expected rc!=0, got rc=$rc"
fi

# --- Case E: gh pr edit 1 --base staging -> allow ---
echo "Case E: gh pr edit --base staging allows"
inc
rc=$(run_hook 'gh pr edit 1 --base staging')
if [ "$rc" = "0" ]; then
  pass_msg "Case E: allowed"
else
  fail_msg "Case E: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

# --- Case F: gh pr edit 1 --title "X" (no --base) -> allow ---
# Title/body-only edits must NOT inherit the fatal-missing-base semantics
# of `gh pr create`.
echo "Case F: gh pr edit without --base allows (title/body-only edit)"
inc
rc=$(run_hook 'gh pr edit 1 --title "X"')
if [ "$rc" = "0" ]; then
  pass_msg "Case F: allowed (edit without --base is not fatal)"
else
  fail_msg "Case F: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

# --- Next-branch routing (#1128) -------------------------------------------
# The hook is branch-agnostic: it reads whatever setup-worktree.sh wrote into
# .claude/base-branch as EXPECTED_BASE. For a next-labelled worktree that file
# contains `next`, so --base next is the only allowed create target. EXPECTED_BASE
# resolves at hook import, so each case runs in a FRESH hook process against a
# project whose base-branch is `next`.
NEXT_PROJ="$WORKDIR/proj-next"
mkdir -p "$NEXT_PROJ/.claude"
printf 'next\n' > "$NEXT_PROJ/.claude/base-branch"
printf 'PIPELINE_BASE_BRANCH="staging"\n' > "$NEXT_PROJ/pipeline.config"

run_hook_in() {
  local proj="$1" command="$2"
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$command")
  set +e
  echo "$payload" | env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$proj" \
    python3 "$HOOK" >"$WORKDIR/out" 2>"$WORKDIR/err"
  local rc=$?
  set -e
  echo "$rc"
}

echo "Case G: next-routing — gh pr create --base next allows (base-branch=next)"
inc
rc=$(run_hook_in "$NEXT_PROJ" 'gh pr create --base next --title T --body B')
if [ "$rc" = "0" ]; then
  pass_msg "Case G: --base next allowed when .claude/base-branch=next"
else
  fail_msg "Case G: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

echo "Case H: next-routing — gh pr create --base staging blocks (base-branch=next)"
inc
rc=$(run_hook_in "$NEXT_PROJ" 'gh pr create --base staging --title T --body B')
if [ "$rc" != "0" ]; then
  pass_msg "Case H: --base staging blocked when .claude/base-branch=next"
else
  fail_msg "Case H: expected rc!=0, got rc=$rc"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
