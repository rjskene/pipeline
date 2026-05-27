#!/bin/bash
set -uo pipefail
#
# Tests for scripts/visual-proof-server-start.sh — the single-responsibility
# bootstrap that composes visual-proof-port-broker.sh to allocate a port, then
# starts a loopback `python3 -m http.server --directory <target> --bind
# 127.0.0.1`, readiness-probes it, and emits a parseable
#   SERVER: pid=<P> port=<PORT> dir=<dir>
# line. Reusable entry point for the single-issue orchestrator path, manual
# operators, and the evaluate-issue-pr inline path (Step 6c). See Issue #527
# (PR #519 follow-up). Auto-discovered by the tests/test*.sh glob.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTER="$REPO_ROOT/scripts/visual-proof-server-start.sh"
PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---- Case (a): argument validation — missing/nonexistent target_dir -> exit 2 ----

# (a1) no args -> exit 2
bash "$STARTER" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && pass_msg "no args -> exit 2 (got: $rc)" || fail_msg "no args -> exit 2 (got: $rc)"

# (a2) slate_index present but target_dir missing -> exit 2
bash "$STARTER" 0 >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && pass_msg "missing target_dir -> exit 2 (got: $rc)" || fail_msg "missing target_dir -> exit 2 (got: $rc)"

# (a3) nonexistent target_dir -> exit 2
bash "$STARTER" 0 "/no/such/dir/$$" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && pass_msg "nonexistent target_dir -> exit 2 (got: $rc)" || fail_msg "nonexistent target_dir -> exit 2 (got: $rc)"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
