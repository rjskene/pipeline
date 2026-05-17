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

# Group 2 — index.html declares the three interaction regions
IDX="$REPO_ROOT/mock-web/index.html"
assert "index has toggle button"        "grep -q 'id=\"toggle-btn\"' '$IDX'"
assert "index has toggle panel"         "grep -q 'id=\"toggle-panel\"' '$IDX'"
assert "index has toggle indicator"     "grep -q 'id=\"toggle-indicator\"' '$IDX'"
assert "index has echo form"            "grep -q 'id=\"echo-form\"' '$IDX'"
assert "index has echo input"           "grep -q 'id=\"echo-input\"' '$IDX'"
assert "index has echo output"          "grep -q 'id=\"echo-output\"' '$IDX'"
assert "index has list root"            "grep -q 'id=\"item-list\"' '$IDX'"
assert "index has list add button"      "grep -q 'id=\"item-add\"' '$IDX'"
assert "index loads app.js"             "grep -q 'src=\"app.js\"' '$IDX'"
assert "index loads style.css"          "grep -q 'href=\"style.css\"' '$IDX'"

# Group 3 — app.js wires the three interactions
APP="$REPO_ROOT/mock-web/app.js"
assert "app.js binds toggle-btn click"   "grep -qE 'toggle-btn.*addEventListener|getElementById..toggle-btn..\..*addEventListener' '$APP'"
assert "app.js flips toggle-panel hidden" "grep -q 'toggle-panel' '$APP' && grep -q 'hidden' '$APP'"
assert "app.js flips indicator class"     "grep -q 'toggle-indicator' '$APP' && grep -qE 'classList\.(toggle|add|remove)' '$APP'"
assert "app.js binds echo-form submit"    "grep -q 'echo-form' '$APP' && grep -q 'submit' '$APP'"
assert "app.js writes to echo-output"     "grep -q 'echo-output' '$APP'"
assert "app.js binds item-add"            "grep -q 'item-add' '$APP'"
assert "app.js mutates item-list"         "grep -q 'item-list' '$APP' && grep -qE 'appendChild|insertAdjacentHTML' '$APP'"
assert "app.js supports list item remove" "grep -qE 'removeChild|\.remove\(' '$APP'"
assert "app.js <= 100 lines"              "[ \"\$(wc -l < '$APP')\" -le 100 ]"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
