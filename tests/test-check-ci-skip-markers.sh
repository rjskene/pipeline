#!/bin/bash
set -euo pipefail

# Tests for hooks/check-ci-skip-markers.py.
# Asserts that GH Actions CI-blocking markers (bracketed forms of
# skip ci / ci skip / no ci / no-ci, plus ***NO_CI***) are blocked
# only when they appear in the --title/--body of `gh pr create` or
# the -m/--message of `git commit`. All other commands (including
# unrelated greps and log searches) pass through cleanly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/check-ci-skip-markers.py"

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

run_hook() {
  local payload="$1"
  set +e
  printf '%s' "$payload" | env -i HOME="$HOME" PATH="/usr/bin:/bin" \
    python3 "$HOOK" >"$WORKDIR/out" 2>"$WORKDIR/err"
  local rc=$?
  set -e
  echo "$rc"
}

echo "Case A: git commit -m with [skip ci] -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"git commit -m \"fix [skip ci] handling\""}}')
if [ "$rc" = "1" ] && grep -q "BLOCKED: CI-blocking marker" "$WORKDIR/err"; then
  pass_msg "blocked with marker error"
else
  fail_msg "expected rc=1 + BLOCKED message, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case B: gh pr create --title containing [ci skip] -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"gh pr create --title \"[ci skip] fix release-please\" --body \"x\" --base staging"}}')
if [ "$rc" = "1" ] && grep -q "BLOCKED: CI-blocking marker" "$WORKDIR/err"; then
  pass_msg "blocked --title with [ci skip]"
else
  fail_msg "expected rc=1, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case C: gh pr create --body containing [no-ci] -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"gh pr create --title \"fix release-please\" --body \"ship [no-ci] guard\" --base staging"}}')
if [ "$rc" = "1" ] && grep -q "BLOCKED: CI-blocking marker" "$WORKDIR/err"; then
  pass_msg "blocked --body with [no-ci]"
else
  fail_msg "expected rc=1, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case D: git commit -m with ***NO_CI*** -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"git commit -m \"feat: handle ***NO_CI*** in payloads\""}}')
if [ "$rc" = "1" ] && grep -q "BLOCKED: CI-blocking marker" "$WORKDIR/err"; then
  pass_msg "blocked ***NO_CI*** literal"
else
  fail_msg "expected rc=1, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case E: case-insensitive [Skip CI] -> blocked"
inc
rc=$(run_hook '{"tool_input":{"command":"git commit -m \"[Skip CI] reword\""}}')
if [ "$rc" = "1" ] && grep -q "BLOCKED: CI-blocking marker" "$WORKDIR/err"; then
  pass_msg "blocked [Skip CI] (case-insensitive)"
else
  fail_msg "expected rc=1, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case F: safe rephrase 'skip-ci' (no brackets) -> passthrough"
inc
rc=$(run_hook '{"tool_input":{"command":"git commit -m \"fix: strip skip-ci from squashed PR body\""}}')
if [ "$rc" = "0" ] && [ ! -s "$WORKDIR/err" ]; then
  pass_msg "passthrough for hyphenated skip-ci"
else
  fail_msg "expected rc=0 + empty stderr, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case G: backticked \`skip ci\` -> passthrough"
inc
rc=$(run_hook '{"tool_input":{"command":"git commit -m \"fix: strip \\`skip ci\\` from squashed PR body\""}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for backticked marker"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case H: unrelated command (git log --grep) -> passthrough"
inc
rc=$(run_hook '{"tool_input":{"command":"git log --grep \"[skip ci]\""}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for git log --grep"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo "Case I: empty tool_input -> passthrough"
inc
rc=$(run_hook '{"tool_input":{}}')
if [ "$rc" = "0" ]; then
  pass_msg "passthrough for empty payload"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/err")"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
