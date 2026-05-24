#!/bin/bash
set -euo pipefail

# Tests for scripts/wait-for-sentinel.sh.
# The helper polls a file for a token with a hard, bounded timeout. On a hit
# it prints the file contents with the token line (and blank lines) stripped
# and exits 0. On timeout it prints an actionable diagnostic to stderr and
# exits non-zero, so a caller's Bash tool surfaces failure instead of wedging.
#
# Cases:
#   A. token already present       -> exit 0, prints filtered content
#   B. token never appears         -> timeout fires, exit !=0, stderr diagnostic
#   C. explicit --timeout honored  -> --timeout 1 returns quickly (bounded)
#   D. missing required args       -> usage error, exit !=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/wait-for-sentinel.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "ERROR: helper not found at $HELPER" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Case A: token already present -> exit 0 + filtered content"
inc
SENTINEL="$WORKDIR/a.log"
printf 'work line one\n__DONE__\n' >"$SENTINEL"
set +e
out=$(bash "$HELPER" "$SENTINEL" "__DONE__" --timeout 5 2>"$WORKDIR/a.err")
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "work line one" && ! echo "$out" | grep -q "__DONE__"; then
  pass_msg "exit 0, stdout has content, token line stripped"
else
  fail_msg "expected rc=0 + filtered stdout, got rc=$rc out=[$out] err=$(cat "$WORKDIR/a.err")"
fi

echo "Case B: token never appears -> timeout, exit !=0, stderr diagnostic"
inc
SENTINEL="$WORKDIR/b.log"
printf 'still running...\n' >"$SENTINEL"
set +e
bash "$HELPER" "$SENTINEL" "__DONE__" --timeout 1 >"$WORKDIR/b.out" 2>"$WORKDIR/b.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q "wait-for-sentinel: timed out after" "$WORKDIR/b.err"; then
  pass_msg "exit !=0 + actionable stderr diagnostic"
else
  fail_msg "expected rc!=0 + 'timed out after' on stderr, got rc=$rc err=$(cat "$WORKDIR/b.err")"
fi

echo "Case C: explicit --timeout 1 is honored (returns quickly, bounded)"
inc
SENTINEL="$WORKDIR/c.log"
printf 'never finishes\n' >"$SENTINEL"
start=$(date +%s)
set +e
bash "$HELPER" "$SENTINEL" "__DONE__" --timeout 1 >/dev/null 2>&1
rc=$?
set -e
end=$(date +%s)
elapsed=$((end - start))
if [ "$rc" -ne 0 ] && [ "$elapsed" -lt 10 ]; then
  pass_msg "bounded at --timeout 1 (elapsed ${elapsed}s, well under default 600s)"
else
  fail_msg "expected rc!=0 and quick return, got rc=$rc elapsed=${elapsed}s"
fi

echo "Case D: missing required args -> usage error"
inc
set +e
bash "$HELPER" >"$WORKDIR/d.out" 2>"$WORKDIR/d.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -qi "usage" "$WORKDIR/d.err"; then
  pass_msg "exit !=0 + usage message on stderr"
else
  fail_msg "expected rc!=0 + usage message, got rc=$rc err=$(cat "$WORKDIR/d.err")"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
