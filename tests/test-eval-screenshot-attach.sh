#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

HELPER="$REPO_ROOT/scripts/eval-screenshot-attach.sh"

assert "eval-screenshot-attach.sh exists"      "[ -f '$HELPER' ]"
assert "eval-screenshot-attach.sh executable"  "[ -x '$HELPER' ]"
assert "uses gh release upload"                "grep -q 'gh release upload' '$HELPER'"
assert "uses --clobber (idempotent re-upload)" "grep -q '\\-\\-clobber' '$HELPER'"
assert "creates release via gh release create" "grep -q 'gh release create' '$HELPER'"
assert "uses canonical eval-evidence- tag prefix" "grep -q 'eval-evidence-' '$HELPER'"

# Usage check: with no args, must exit non-zero AND print a 'usage:' line.
if [ -x "$HELPER" ]; then
  OUT="$(bash "$HELPER" </dev/null 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'usage:'; then
    pass_msg "no-args invocation prints usage and exits non-zero"
  else
    fail_msg "no-args invocation prints usage and exits non-zero (rc=$rc, out=$OUT)"
  fi
else
  fail_msg "no-args invocation prints usage and exits non-zero (helper not executable)"
fi

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
