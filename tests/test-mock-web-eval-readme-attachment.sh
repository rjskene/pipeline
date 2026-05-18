#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

README="$REPO_ROOT/dev/mock-web-eval/README.md"

assert "README exists"                                  "[ -f '$README' ]"
assert "STUB header is gone"                            "! grep -q 'STUB / DEFERRED' '$README'"
assert "placeholder 'Decision pending' is gone"         "! grep -q 'Decision pending' '$README'"
assert "new release-assets header is present"           "grep -q 'Attachment mechanism — release assets' '$README'"
assert "documents canonical eval-evidence-<PR> tag"     "grep -q 'eval-evidence-<PR>' '$README'"
assert "references eval-screenshot-attach.sh helper"    "grep -q 'eval-screenshot-attach.sh' '$README'"
assert "references eval-screenshot-cleanup.sh helper"   "grep -q 'eval-screenshot-cleanup.sh' '$README'"
assert "notes that releases bypass back-sync"           "grep -q 'back-sync' '$README'"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
