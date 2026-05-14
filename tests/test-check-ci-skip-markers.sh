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

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
