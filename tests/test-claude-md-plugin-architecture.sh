#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$REPO_ROOT/CLAUDE.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
assert "Plugin architecture heading present" "grep -qE '^## Plugin architecture' '$F'"
assert "Mentions CLAUDE_PLUGIN_ROOT or ~/.claude/plugins" "grep -qE 'CLAUDE_PLUGIN_ROOT|~/\.claude/plugins/claude-pipeline' '$F'"
assert "Mentions pipeline: namespace prefix" "grep -qF 'pipeline:' '$F'"
assert "Documents Bash-subshell self-resolve" "grep -q 'Bash subshells' '$F'"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
