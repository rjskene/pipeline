#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

HELPER="$REPO_ROOT/scripts/eval-screenshot-cleanup.sh"

assert "eval-screenshot-cleanup.sh exists"          "[ -f '$HELPER' ]"
assert "eval-screenshot-cleanup.sh executable"      "[ -x '$HELPER' ]"
assert "uses gh release delete"                     "grep -q 'gh release delete' '$HELPER'"
assert "uses --cleanup-tag (also removes the tag)"  "grep -q '\\-\\-cleanup-tag' '$HELPER'"
assert "uses --yes (non-interactive)"               "grep -q '\\-\\-yes' '$HELPER'"
assert "has usage block"                             "grep -q 'usage:' '$HELPER'"

# Fail-soft: missing release must exit 0 (must never block auto-merge).
if [ -x "$HELPER" ]; then
  OUT="$(PIPELINE_REPO=HTS-COLLAB-ORG/claude-pipeline bash "$HELPER" 99999999 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    pass_msg "missing-release invocation is fail-soft (exit 0)"
  else
    fail_msg "missing-release invocation is fail-soft (exit 0) (rc=$rc, out=$OUT)"
  fi
else
  fail_msg "missing-release invocation is fail-soft (helper not executable)"
fi

# No-args invocation prints usage and exits non-zero.
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
