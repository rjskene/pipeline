#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

assert() {
  local desc="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then echo "  PASS: $desc"; PASS=$((PASS+1)); else echo "  FAIL: $desc"; FAIL=$((FAIL+1)); fi
}

for f in "scripts/spawn-claude.sh"; do
  assert "$f exists"                            "[ -f \"$REPO_ROOT/$f\" ]"
  assert "$f uses /pipeline:\${SKILL} namespace" "grep -qF \"'/pipeline:\\\${SKILL} \\\${ISSUE_NUM}'\" \"$REPO_ROOT/$f\""
  assert "$f has no bare /\${SKILL} invocation"  "! grep -E \"CLAUDE_ARGV.*'/\\\\\\\$\\{SKILL\\}\" \"$REPO_ROOT/$f\""
done

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
