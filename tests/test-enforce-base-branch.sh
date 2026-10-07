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

# --- Unexpanded $PIPELINE_BASE_BRANCH token (#1323) ------------------------
# skills/execute-issue-plan/SKILL.md Step 9b prescribes
# `gh pr create --base "$PIPELINE_BASE_BRANCH" ...` — quoted but unexpanded
# in the command TEXT the hook sees. The token is equal-by-construction to
# EXPECTED_BASE when PIPELINE_BASE_BRANCH is unset in the hook's env (the
# shell would expand it from the same pipeline.config); if it IS exported to
# a different branch, that disagreement must still deny.
VAR_TOKEN_STR='$'"PIPELINE_BASE_BRANCH"
VAR_TOKEN_BRACED='${'"PIPELINE_BASE_BRANCH"'}'

echo "Case I: quoted \$PIPELINE_BASE_BRANCH token allows (env unset)"
inc
rc=$(run_hook "gh pr create --base \"$VAR_TOKEN_STR\" --title T --body B")
if [ "$rc" = "0" ]; then
  pass_msg "Case I: allowed"
else
  fail_msg "Case I: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

echo "Case J: quoted \${PIPELINE_BASE_BRANCH} braced token allows (env unset)"
inc
rc=$(run_hook "gh pr create --base \"$VAR_TOKEN_BRACED\" --title T --body B")
if [ "$rc" = "0" ]; then
  pass_msg "Case J: allowed"
else
  fail_msg "Case J: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

echo "Case K: \$PIPELINE_BASE_BRANCH token blocks when exported to a different branch"
inc
payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' \
  "gh pr create --base \"$VAR_TOKEN_STR\" --title T --body B")
set +e
echo "$payload" | env -i \
  HOME="$HOME" \
  PATH="/usr/bin:/bin" \
  CLAUDE_PROJECT_DIR="$PROJ" \
  PIPELINE_BASE_BRANCH="main" \
  python3 "$HOOK" >"$WORKDIR/out" 2>"$WORKDIR/err"
rc=$?
set -e
if [ "$rc" != "0" ]; then
  pass_msg "Case K: blocked (exported PIPELINE_BASE_BRANCH=main disagrees with configured base staging)"
else
  fail_msg "Case K: expected rc!=0, got rc=$rc"
fi

# --- Command-head masking (#1327) ------------------------------------------
# The hook must decide from the command HEAD (command_mask.segments()), not a
# raw-text substring scan — so `gh pr create` living only inside a grep
# pattern, a Python replacement string, or a heredoc body is not a command;
# but a `bash -c` operand still IS a command (depth-1 recursion).

echo "Case L: grep pattern operand containing 'gh pr create' allows"
inc
rc=$(run_hook "grep -n 'gh pr create' skills/x.md")
if [ "$rc" = "0" ]; then
  pass_msg "Case L: allowed (grep pattern, not a command)"
else
  fail_msg "Case L: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

echo "Case M: python3 -c replacement string containing 'gh pr create --base foo' allows"
inc
rc=$(run_hook 'python3 -c '"'"'print("gh pr create --base foo")'"'"'')
if [ "$rc" = "0" ]; then
  pass_msg "Case M: allowed (Python string literal, not a command)"
else
  fail_msg "Case M: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

echo "Case N: heredoc body spelling 'gh pr create --base main' allows"
inc
HEREDOC_CMD=$(printf 'cat <<%s\ngh pr create --base main\n%s' "EOF" "EOF")
rc=$(run_hook "$HEREDOC_CMD")
if [ "$rc" = "0" ]; then
  pass_msg "Case N: allowed (heredoc body, not a command)"
else
  fail_msg "Case N: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

echo "Case O: bash -c operand running 'gh pr create --base main' still blocks"
inc
rc=$(run_hook 'bash -c "gh pr create --base main"')
if [ "$rc" != "0" ] && grep -q "main" "$WORKDIR/err"; then
  pass_msg "Case O: blocked (depth-1 recursion into -c operand still sees the real command)"
else
  fail_msg "Case O: expected rc!=0 with 'main' in stderr, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

# --- Line-continuation shape (#1342) ----------------------------------------
# A bare `\`+newline continuation before the real command head must not mask
# the command from this guard — same as the single-line form.

echo "Case P: continuation shape — env assignment + backslash-newline before gh pr create --base main blocks"
inc
rc=$(run_hook $'FOO=1 \\\ngh pr create --base main --title T --body B')
if [ "$rc" != "0" ]; then
  pass_msg "Case P: blocked (continuation-masked head still resolves to gh pr create)"
else
  fail_msg "Case P: expected rc!=0, got rc=$rc"
fi

# --- Release promotion lane (#1356) ----------------------------------------
# Allow ONLY: --base == PIPELINE_RELEASE_BRANCH (default main) AND --head == EXPECTED_BASE.
REL_PROJ="$WORKDIR/proj-rel"
mkdir -p "$REL_PROJ/.claude"
printf 'staging\n' > "$REL_PROJ/.claude/base-branch"
printf 'PIPELINE_BASE_BRANCH="staging"\nPIPELINE_RELEASE_BRANCH="release"\n' > "$REL_PROJ/pipeline.config"

echo "Case Q: promotion --base main --head staging allows (a)"
inc; rc=$(run_hook 'gh pr create --base main --head staging --title T --body B')
[ "$rc" = "0" ] && pass_msg "Case Q: allowed" || fail_msg "Case Q: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"

echo "Case R: promotion --base=main --head=staging (equals form) allows (a)"
inc; rc=$(run_hook 'gh pr create --base=main --head=staging --title T --body B')
[ "$rc" = "0" ] && pass_msg "Case R: allowed" || fail_msg "Case R: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"

echo "Case S: --base main --head feature/x blocks (b)"
inc; rc=$(run_hook 'gh pr create --base main --head feature/x --title T --body B')
[ "$rc" != "0" ] && pass_msg "Case S: blocked" || fail_msg "Case S: expected rc!=0, got rc=$rc"

echo "Case T: --base main with --head omitted blocks (c)"
inc; rc=$(run_hook 'gh pr create --base main --title T --body B')
[ "$rc" != "0" ] && pass_msg "Case T: blocked" || fail_msg "Case T: expected rc!=0, got rc=$rc"

echo "Case U: PIPELINE_RELEASE_BRANCH=release — --base main --head staging blocks (d)"
inc; rc=$(run_hook_in "$REL_PROJ" 'gh pr create --base main --head staging --title T --body B')
[ "$rc" != "0" ] && pass_msg "Case U: blocked" || fail_msg "Case U: expected rc!=0, got rc=$rc"

echo "Case U2: PIPELINE_RELEASE_BRANCH=release — --base release --head staging allows (d, knob is read)"
inc; rc=$(run_hook_in "$REL_PROJ" 'gh pr create --base release --head staging --title T --body B')
[ "$rc" = "0" ] && pass_msg "Case U2: allowed" || fail_msg "Case U2: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"

echo "Case V: next-routing unchanged — --base main --head feature/x blocks when base-branch=next (e)"
inc; rc=$(run_hook_in "$NEXT_PROJ" 'gh pr create --base main --head feature/x --title T --body B')
[ "$rc" != "0" ] && pass_msg "Case V: blocked" || fail_msg "Case V: expected rc!=0, got rc=$rc"

echo "Case V2: next-routing unchanged — --base next --head feature/x allows when base-branch=next (e)"
inc; rc=$(run_hook_in "$NEXT_PROJ" 'gh pr create --base next --head feature/x --title T --body B')
[ "$rc" = "0" ] && pass_msg "Case V2: allowed" || fail_msg "Case V2: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"

echo "Case X: deny message for --base main names the promotion shape"
inc; rc=$(run_hook 'gh pr create --base main --title T --body B')
if [ "$rc" != "0" ] && grep -q -- "--base main --head staging" "$WORKDIR/err"; then
  pass_msg "Case X: blocked with promotion hint"
else
  fail_msg "Case X: expected rc!=0 and '--base main --head staging' in stderr, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

echo "Case Y: unterminated quote (legacy scan) — --base main --head staging still blocks (fail-closed)"
inc; rc=$(run_hook 'gh pr create --base main --head staging --title "T')
[ "$rc" != "0" ] && pass_msg "Case Y: blocked (legacy scan has no release lane)" || fail_msg "Case Y: expected rc!=0, got rc=$rc"

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
