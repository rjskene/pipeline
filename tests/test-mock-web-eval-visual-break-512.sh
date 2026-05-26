#!/bin/bash
# Issue #512 — dogfood(visual-proof): screenshot-only failure case.
# Asserts the deliberate visual break: the .counter-reset button is hidden via
# `visibility: hidden` in style.css. The button stays in the DOM (presence /
# class / click-handler wiring unchanged — see Group 9 of
# tests/test-mock-web-eval-files.sh), so the predicate harness stays GREEN while
# the button is invisible on screen. This is the screenshot-only break the
# evaluator is being tested against.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

CSS="$REPO_ROOT/mock-web-eval/target/style.css"

assert "style.css hides .counter-reset via visibility:hidden" \
  "grep -qE '\.counter-reset[^}]*visibility:[[:space:]]*hidden' '$CSS'"

echo ""
echo "test-mock-web-eval-visual-break-512: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
