#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

# Group 1 — file existence
assert "mock-web/index.html exists"     "[ -f '$REPO_ROOT/mock-web/index.html' ]"
assert "mock-web/app.js exists"         "[ -f '$REPO_ROOT/mock-web/app.js' ]"
assert "mock-web/style.css exists"      "[ -f '$REPO_ROOT/mock-web/style.css' ]"
assert "Dockerfile.mock-web-eval exists" "[ -f '$REPO_ROOT/Dockerfile.mock-web-eval' ]"
assert "compose.mock-web-eval.yml exists" "[ -f '$REPO_ROOT/compose.mock-web-eval.yml' ]"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
