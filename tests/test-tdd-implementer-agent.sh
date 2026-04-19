#!/bin/bash
set -euo pipefail

# Tests for the tdd-implementer subagent definition at
# .claude-pipeline/agents/tdd-implementer.md.
# Verifies frontmatter (name, tools, model: inherit, color), tool exclusions
# (no Agent, no Skill), and body content (TDD discipline, forbidden flags).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_FILE="$SCRIPT_DIR/../agents/tdd-implementer.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

echo "Test 1: agent file exists"
inc
if [ -f "$AGENT_FILE" ]; then
  pass_msg "agent file present"
else
  fail_msg "agent file missing at $AGENT_FILE"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

# Read frontmatter (between two `---` lines at the top)
FM=$(awk '/^---$/{c++; next} c==1' "$AGENT_FILE")
BODY=$(awk '/^---$/{c++; next} c>=2' "$AGENT_FILE")

echo "Test 2: frontmatter has name: tdd-implementer"
inc
if echo "$FM" | grep -qE '^name:[[:space:]]*tdd-implementer$'; then
  pass_msg "name correct"
else
  fail_msg "frontmatter name not 'tdd-implementer'"
  echo "$FM" | sed 's/^/    /'
fi

echo "Test 3: frontmatter has model: inherit"
inc
if echo "$FM" | grep -qE '^model:[[:space:]]*inherit$'; then
  pass_msg "model: inherit present"
else
  fail_msg "expected 'model: inherit' in frontmatter"
fi

echo "Test 4: frontmatter has tools list"
inc
if echo "$FM" | grep -qE '^tools:'; then
  pass_msg "tools key present"
else
  fail_msg "expected 'tools:' key in frontmatter"
fi

echo "Test 5: tools includes Read, Write, Edit, Bash, Grep, Glob"
inc
TOOLS_LINE=$(echo "$FM" | grep -E '^tools:' | head -1)
MISSING=""
for t in Read Write Edit Bash Grep Glob; do
  if ! echo "$TOOLS_LINE" | grep -q "$t"; then
    MISSING="$MISSING $t"
  fi
done
if [ -z "$MISSING" ]; then
  pass_msg "all required tools present"
else
  fail_msg "missing tools:$MISSING"
  echo "    tools line: $TOOLS_LINE"
fi

echo "Test 6: tools EXCLUDES Agent and Skill"
inc
BAD=""
for t in Agent Skill; do
  # Use word boundary check so a tool named "AgentX" wouldn't fool us
  if echo "$TOOLS_LINE" | grep -qE "(^|[^A-Za-z])${t}([^A-Za-z]|$)"; then
    BAD="$BAD $t"
  fi
done
if [ -z "$BAD" ]; then
  pass_msg "Agent and Skill correctly absent"
else
  fail_msg "tools must exclude:$BAD"
  echo "    tools line: $TOOLS_LINE"
fi

echo "Test 7: frontmatter has description"
inc
if echo "$FM" | grep -qE '^description:'; then
  pass_msg "description present"
else
  fail_msg "expected 'description:' in frontmatter"
fi

echo "Test 8: body mentions failing test first"
inc
if echo "$BODY" | grep -iqE 'failing test first|test.*first|red[- ]green'; then
  pass_msg "body mandates test-first"
else
  fail_msg "body does not mandate test-first"
fi

echo "Test 9: body forbids --no-verify"
inc
if echo "$BODY" | grep -q -- '--no-verify'; then
  pass_msg "body references --no-verify (forbidden)"
else
  fail_msg "body must reference --no-verify as forbidden"
fi

echo "Test 10: body forbids dispatching subagents (no Agent tool use)"
inc
if echo "$BODY" | grep -iqE 'do not dispatch|never dispatch|no agent|never invoke.*subagent|leaf'; then
  pass_msg "body forbids subagent dispatch"
else
  fail_msg "body must forbid subagent dispatch (it is a leaf executor)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
