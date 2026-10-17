#!/bin/bash
set -euo pipefail

# Tests for scripts/strip-code-spans.sh — shared stdin -> stdout code-span
# suppressor (#1500). Fence lines (first non-blank chars are a triple
# backtick) toggle code mode and are dropped with their contents; on every
# other line single-backtick inline spans are removed; prose is preserved.
# Consumers: parse-tracker-children.sh --fallback-mentions and the
# MARKER-PARSE / HINT-PARSE blocks in skills/plan-issue/references/classification.md.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/strip-code-spans.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

FENCE='```'

# ---- Case a: --help ----
echo "Case a: --help exits 0 and prints usage"
inc
rc=0
out=$(bash "$HELPER" --help 2>&1 </dev/null) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi 'usage'; then
  pass_msg "Case a: --help rc=0 with usage"
else
  fail_msg "Case a: rc=$rc out='$out'"
fi

# ---- Case b: unknown arg ----
echo "Case b: unknown arg exits 2"
inc
rc=0
bash "$HELPER" --bogus </dev/null >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass_msg "Case b: unknown arg rc=2"
else
  fail_msg "Case b: expected rc=2 got rc=$rc"
fi

# ---- Case c: fenced blocks removed (incl. indented fence open) ----
echo "Case c: fenced blocks dropped, prose kept"
inc
C_IN="before
$FENCE
inside one
$FENCE
middle
   ${FENCE}bash
inside two
   $FENCE
after"
C_WANT="before
middle
after"
out=$(printf '%s\n' "$C_IN" | bash "$HELPER" 2>"$TMP/err-c") || true
if [ "$out" = "$C_WANT" ] && [ ! -s "$TMP/err-c" ]; then
  pass_msg "Case c: fenced content removed"
else
  fail_msg "Case c: expected '$C_WANT' got '$out'"
fi

# ---- Case d: inline span removed, rest of line kept ----
echo "Case d: inline span removed"
inc
D_IN='see `#999 code` and #12 here'
D_WANT='see  and #12 here'
out=$(printf '%s\n' "$D_IN" | bash "$HELPER") || true
if [ "$out" = "$D_WANT" ]; then
  pass_msg "Case d: inline span blanked, prose kept"
else
  fail_msg "Case d: got '$out'"
fi

# ---- Case e: unterminated fence drops to EOF ----
echo "Case e: unterminated fence drops to EOF"
inc
E_IN="keep me
$FENCE
never closed
still code"
out=$(printf '%s\n' "$E_IN" | bash "$HELPER") || true
if [ "$out" = 'keep me' ]; then
  pass_msg "Case e: unterminated fence swallows to EOF"
else
  fail_msg "Case e: got '$out'"
fi

# ---- Case f: identical output under mawk ----
if command -v mawk >/dev/null 2>&1; then
  SHIM="$TMP/awkshim"
  mkdir -p "$SHIM"
  ln -sf "$(command -v mawk)" "$SHIM/awk"
  echo "Case f: same output when awk is mawk"
  inc
  out=$(printf '%s\n' "$C_IN" | PATH="$SHIM:$PATH" bash "$HELPER" 2>"$TMP/err-f") || true
  out2=$(printf '%s\n' "$D_IN" | PATH="$SHIM:$PATH" bash "$HELPER" 2>>"$TMP/err-f") || true
  if [ "$out" = "$C_WANT" ] && [ "$out2" = "$D_WANT" ] && [ ! -s "$TMP/err-f" ]; then
    pass_msg "Case f: mawk output matches"
  else
    fail_msg "Case f: got '$out' / '$out2' (stderr: $(cat "$TMP/err-f"))"
  fi
else
  echo "Case f: mawk not installed — skipping POSIX-portability check"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
