#!/bin/bash
set -uo pipefail
#
# tests/test-agents-playwright-tools.sh — execute and evaluate agents carry
# the Playwright MCP tools (#1588).
#
#   P1  stage-executor, stage-reader and tdd-implementer `tools:` lines name
#       `mcp__playwright__*`
#   P2  stage-reader and tdd-implementer name neither `Agent` nor `Skill`;
#       stage-executor names no `Skill`
#   P3  no agent description still claims "no MCP catalogue" without the
#       Playwright exception
#   P4  dispatch-routing.md no longer routes browser issues to the built-in
#       type on the claim that the stage types carry no Playwright MCP tools
#   P5  negative controls for the matchers

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTING="$ROOT/skills/fullsend/references/dispatch-routing.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

frontmatter() { awk 'NR==1 && /^---$/ { infm=1; next } infm && /^---$/ { exit } infm { print }' "$1"; }
tools_line() { frontmatter "$1" | grep -E '^tools:' | head -1; }
has_playwright() { printf '%s\n' "$1" | grep -qE '(^|[ ,:])mcp__playwright__\*([ ,]|$)'; }
names_tool() { printf '%s\n' "$1" | grep -qE "(^|[^A-Za-z_])$2([^A-Za-z_]|\$)"; }

AGENTS="stage-executor stage-reader tdd-implementer"

# ---------------------------------------------------------------------------
scenario "P1: tools lines name mcp__playwright__*"
for a in $AGENTS; do
  f="$ROOT/agents/$a.md"
  [ -f "$f" ] || { fail_msg "agents/$a.md missing"; continue; }
  T="$(tools_line "$f")"
  if has_playwright "$T"; then pass_msg "$a: tools names mcp__playwright__*"; else
    fail_msg "$a: tools line '$T' lacks mcp__playwright__*"; fi
done

# ---------------------------------------------------------------------------
scenario "P2: leaf/reader contracts (no Agent/Skill; executor no Skill)"
for a in stage-reader tdd-implementer; do
  T="$(tools_line "$ROOT/agents/$a.md")"
  for t in Agent Skill; do
    if names_tool "$T" "$t"; then fail_msg "$a: tools names $t"; else pass_msg "$a: tools excludes $t"; fi
  done
done
T="$(tools_line "$ROOT/agents/stage-executor.md")"
if names_tool "$T" Skill; then fail_msg "stage-executor: tools names Skill"; else pass_msg "stage-executor: tools excludes Skill"; fi

# ---------------------------------------------------------------------------
scenario "P3: descriptions drop the bare 'no MCP catalogue' claim"
for a in stage-executor stage-reader; do
  D="$(frontmatter "$ROOT/agents/$a.md" | grep -E '^description:' | head -1)"
  if printf '%s\n' "$D" | grep -qF 'no MCP catalogue'; then
    fail_msg "$a: description still says 'no MCP catalogue'"
  elif printf '%s\n' "$D" | grep -qF 'the Playwright MCP tools and no other MCP catalogue'; then
    pass_msg "$a: description names the Playwright MCP exception"
  else
    fail_msg "$a: description lacks 'the Playwright MCP tools and no other MCP catalogue'"
  fi
done

# ---------------------------------------------------------------------------
scenario "P4: dispatch-routing drops the browser-check carve-out"
if grep -qF 'carry no Playwright MCP tools' "$ROUTING"; then
  fail_msg "dispatch-routing.md still says the stage types carry no Playwright MCP tools"
else
  pass_msg "dispatch-routing.md drops the no-Playwright claim"
fi
if grep -qF 'Browser-check carve-out' "$ROUTING"; then
  fail_msg "dispatch-routing.md still carries the Browser-check carve-out"
else
  pass_msg "dispatch-routing.md carries no Browser-check carve-out"
fi
if grep -F 'mcp__playwright__*' "$ROUTING" | grep -qF 'pipeline:tdd-implementer'; then
  pass_msg "dispatch-routing.md says the stage types and tdd-implementer carry mcp__playwright__*"
else
  fail_msg "dispatch-routing.md lacks the mcp__playwright__* sentence naming pipeline:tdd-implementer"
fi

# ---------------------------------------------------------------------------
scenario "P5: negative controls"
if has_playwright "tools: Read, Write, Edit, Bash, Grep, Glob"; then fail_msg "matcher accepts a line without the entry"; else pass_msg "matcher rejects a line without the entry"; fi
if has_playwright "tools: Read, mcp__playwright__browser_click"; then fail_msg "matcher accepts a single tool for the wildcard"; else pass_msg "matcher rejects a single tool for the wildcard"; fi
if names_tool "tools: Read, Glob, Skill" Skill; then pass_msg "names_tool catches Skill"; else fail_msg "names_tool misses Skill"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
