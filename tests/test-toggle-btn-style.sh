#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

CSS="$REPO_ROOT/mock-web/style.css"

assert "style.css defines #toggle-btn selector"      "grep -qE '#toggle-btn[[:space:]]*\\{' '$CSS'"
BASE_BLOCK="$(awk '/^#toggle-btn[[:space:]]*\{/{flag=1} flag{print} /\}/{if(flag){flag=0; exit}}' "$CSS")"
assert "#toggle-btn has background-color #2563eb"    "echo \"\$BASE_BLOCK\" | grep -qiE 'background(-color)?:[[:space:]]*#2563eb'"
assert "#toggle-btn has white text color"            "echo \"\$BASE_BLOCK\" | grep -qiE 'color:[[:space:]]*(#fff|#ffffff|white)'"
assert "#toggle-btn has border-radius 8px"           "echo \"\$BASE_BLOCK\" | grep -qiE 'border-radius:[[:space:]]*8px'"
assert "#toggle-btn has padding 8px 16px"            "echo \"\$BASE_BLOCK\" | grep -qiE 'padding:[[:space:]]*8px[[:space:]]+16px'"

assert "style.css defines #toggle-btn:hover"         "grep -qE '#toggle-btn:hover[[:space:]]*\\{' '$CSS'"
HOVER_BLOCK="$(awk '/^#toggle-btn:hover[[:space:]]*\{/{flag=1} flag{print} /\}/{if(flag){flag=0; exit}}' "$CSS")"
assert "#toggle-btn:hover has darker background"     "echo \"\$HOVER_BLOCK\" | grep -qiE 'background(-color)?:[[:space:]]*#[0-9a-f]{3,6}'"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
