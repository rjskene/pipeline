#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_absent() {
  if [ ! -e "$REPO_ROOT/$2" ]; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 ($2 still exists)"; FAIL=$((FAIL+1)); fi
}
assert_no_grep() {
  if ! grep -rqF "$2" "$REPO_ROOT/skills" "$REPO_ROOT/.claude/skills" 2>/dev/null; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (found '$2' in skills)"; FAIL=$((FAIL+1)); fi
}
assert_absent "install.sh removed"                         "install.sh"
assert_absent "scripts/check-subtree-drift.sh removed"     "scripts/check-subtree-drift.sh"
assert_absent "scripts/resolve-subtree-drift.sh removed"   "scripts/resolve-subtree-drift.sh"
assert_absent "rendered check-subtree-drift removed"       ".claude/scripts/check-subtree-drift.sh"
assert_absent "rendered resolve-subtree-drift removed"     ".claude/scripts/resolve-subtree-drift.sh"
assert_no_grep "no resolve-subtree-drift in skills"        "resolve-subtree-drift.sh"
assert_no_grep "no check-subtree-drift in skills"          "check-subtree-drift.sh"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
