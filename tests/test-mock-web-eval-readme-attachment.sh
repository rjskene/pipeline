#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

README="$REPO_ROOT/mock-web-eval/replay/README.md"

assert "README exists"                                  "[ -f '$README' ]"
assert "STUB header is gone"                            "! grep -q 'STUB / DEFERRED' '$README'"
assert "placeholder 'Decision pending' is gone"         "! grep -q 'Decision pending' '$README'"
assert "new in-branch-commits header is present"        "grep -q 'Attachment mechanism — in-branch git commits' '$README'"
assert "documents .eval-screenshots/ in-worktree path"  "grep -q '\\.eval-screenshots/' '$README'"
assert "documents branch-pinned raw URL shape"          "grep -qE 'raw\\.githubusercontent\\.com/.*\\.eval-screenshots/' '$README'"
assert "no longer documents stale SHA-pinned mock-web-eval/screenshots URL" \
  "! grep -qE 'github\\.com/.*/raw/.*mock-web-eval/screenshots/' '$README'"
assert "references eval-screenshot-attach.sh helper"    "grep -q 'eval-screenshot-attach.sh' '$README'"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
