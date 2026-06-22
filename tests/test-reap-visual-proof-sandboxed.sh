#!/bin/bash
# Static sandbox guard for tests/test-reap-stale-visual-proof-servers.sh
#
# Asserts two invariants that prove the reaper test cannot touch live host
# processes or the real worktree registry:
#
#   1. Every line that invokes `bash "$HELPER"` also sets PIPELINE_REPO_ROOT
#      on that same line (env-prefix). Zero unsandboxed invocations allowed.
#
#   2. The test creates a `pgrep` PATH-stub (writes a file named `pgrep` into
#      a stub dir and puts that dir on PATH) so the reaper never enumerates
#      real host processes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/test-reap-stale-visual-proof-servers.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# ---- Invariant 1: no unsandboxed bash "$HELPER" invocations ----
echo "Invariant 1: every 'bash \"\$HELPER\"' line also sets PIPELINE_REPO_ROOT"
inc

# Find lines that call bash "$HELPER" but do NOT also contain PIPELINE_REPO_ROOT.
unsandboxed_count=$(grep -n 'bash "\$HELPER"' "$TARGET" \
  | grep -v 'PIPELINE_REPO_ROOT' \
  | wc -l) || unsandboxed_count=0

if [ "$unsandboxed_count" -eq 0 ]; then
  pass_msg "all bash \"\$HELPER\" lines carry PIPELINE_REPO_ROOT (count=0 unsandboxed)"
else
  fail_msg "$unsandboxed_count unsandboxed bash \"\$HELPER\" line(s) found (PIPELINE_REPO_ROOT missing):"
  grep -n 'bash "\$HELPER"' "$TARGET" | grep -v 'PIPELINE_REPO_ROOT' | sed 's/^/    /'
fi

# ---- Invariant 2: a pgrep PATH-stub is created ----
echo "Invariant 2: test creates a 'pgrep' PATH-stub file"
inc

# Look for evidence that the test writes a file named pgrep in a stub dir.
if grep -qE '(>\s*"\$STUB/pgrep"|> "\$\{STUB\}/pgrep"|pgrep.*chmod|chmod.*pgrep)' "$TARGET" 2>/dev/null \
   || grep -qE '"[^"]*pgrep[^"]*"[[:space:]]*;[[:space:]]*chmod' "$TARGET" 2>/dev/null \
   || grep -q '> "$STUB/pgrep"' "$TARGET" 2>/dev/null \
   || grep -q '"$STUB/pgrep"' "$TARGET" 2>/dev/null; then
  pass_msg "pgrep PATH-stub creation found in target"
else
  fail_msg "no pgrep PATH-stub creation found in target (grep for '\$STUB/pgrep' or similar)"
fi

echo ""
echo "================================"
echo "Tests: $TESTS Pass: $PASS Fail: $FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
