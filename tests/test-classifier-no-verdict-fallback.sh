#!/bin/bash
set -uo pipefail
#
# tests/test-classifier-no-verdict-fallback.sh — a classifier no-verdict on
# Write/Edit falls back to Bash; the Playwright pattern has two underscores.
#
#   N1  execute-issue-plan body and tdd-implementer body carry the fallback
#   N2  execute + evaluate `allowed-tools` name `mcp__playwright__*`, and
#       neither SKILL.md carries the one-underscore `mcp__playwright_*`
#   N3  tdd-implementer `tools:` line is unchanged
#   N4  negative controls

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/skills/execute-issue-plan/SKILL.md"
EVAL="$ROOT/skills/evaluate-issue-pr/SKILL.md"
TDD="$ROOT/agents/tdd-implementer.md"
# shellcheck source=tests/_lib/skill-body.sh
source "$ROOT/tests/_lib/skill-body.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

frontmatter() { awk 'NR==1 && /^---$/ { infm=1; next } infm && /^---$/ { exit } infm { print }' "$1"; }
# has_fallback <text>: names the no-verdict trigger, the Bash route, and no
# hand-back. Text is flattened (prose may wrap) and grepped from a here-string,
# never a pipe (grep -q would SIGPIPE the producer under pipefail).
has_fallback() {
  local flat="${1//$'\n'/ }"
  grep -qF 'refused because the auto-mode classifier gave no verdict, make the change through Bash' <<<"$flat" \
    && grep -qF 'never hand back or stop for it' <<<"$flat"
}
allowed_tools() { frontmatter "$1" | grep -E '^allowed-tools:' | head -1; }
two_underscore() { grep -qE '(^|[ ,:])mcp__playwright__\*([ ,]|$)' <<<"$1"; }

# ---------------------------------------------------------------------------
scenario "N1: no-verdict Bash fallback"
if has_fallback "$(skill_body "$EXEC")"; then pass_msg "execute-issue-plan body carries the fallback"; else
  fail_msg "execute-issue-plan body lacks the no-verdict Bash fallback"; fi
if has_fallback "$(skill_body "$TDD")"; then pass_msg "tdd-implementer body carries the fallback"; else
  fail_msg "tdd-implementer body lacks the no-verdict Bash fallback"; fi

# ---------------------------------------------------------------------------
scenario "N2: allowed-tools spell mcp__playwright__*"
for f in "$EXEC" "$EVAL"; do
  rel="${f#"$ROOT"/}"
  A="$(allowed_tools "$f")"
  if two_underscore "$A"; then pass_msg "$rel: allowed-tools names mcp__playwright__*"; else
    fail_msg "$rel: allowed-tools '$A' lacks mcp__playwright__*"; fi
  if grep -qF 'mcp__playwright_*' "$f"; then fail_msg "$rel: still carries one-underscore mcp__playwright_*"; else
    pass_msg "$rel: no one-underscore mcp__playwright_*"; fi
done

# ---------------------------------------------------------------------------
scenario "N3: tdd-implementer tools line untouched"
T="$(frontmatter "$TDD" | grep -E '^tools:' | head -1)"
if [ "$T" = "tools: Read, Write, Edit, Bash, Grep, Glob, ToolSearch, mcp__playwright__*" ]; then pass_msg "tools line unchanged"; else
  fail_msg "tools line changed: '$T'"; fi

# ---------------------------------------------------------------------------
scenario "N4: negative controls"
if two_underscore "allowed-tools: Read, mcp__playwright_*"; then fail_msg "matcher accepts one underscore"; else pass_msg "matcher rejects one underscore"; fi
if has_fallback "If Write is refused, stop and tell the user."; then fail_msg "fallback matcher accepts a stop"; else pass_msg "fallback matcher rejects a stop"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
