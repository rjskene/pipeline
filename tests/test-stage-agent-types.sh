#!/bin/bash
set -uo pipefail
#
# tests/test-stage-agent-types.sh — lean per-stage agent types.
#
# Stage agents (plan, plan-eval, execute A/B/C-inline, pr-eval) dispatch as
# plugin agents with a narrow `tools:` list instead of `general-purpose`, whose
# boot loads the harness's full tool catalogue.
#
#   S1  both agent files exist; plugin.json agents[] registers them; agents[0]
#       is still tdd-implementer
#   S2  frontmatter name: + exact tools: lines
#   S3  no model: line (the dispatch model= pins it)
#   S4  bodies 20..80 words

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/.claude-plugin/plugin.json"
READER="$ROOT/agents/stage-reader.md"
EXECUTOR="$ROOT/agents/stage-executor.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

# frontmatter <file> -> the lines between the first two `---` markers
frontmatter() { awk 'NR==1 && /^---$/ { infm=1; next } infm && /^---$/ { exit } infm { print }' "$1"; }
# agent_body <file> -> everything after the closing frontmatter `---`
agent_body() { awk 'c >= 2 { print; next } /^---$/ { c++ }' "$1"; }

# ---------------------------------------------------------------------------
scenario "S1: agent files exist and are registered"

for f in "$READER" "$EXECUTOR"; do
  if [ -f "$f" ]; then pass_msg "${f#"$ROOT"/} exists"; else fail_msg "${f#"$ROOT"/} missing"; fi
done
AGENTS="$(jq -r '.agents[]' "$MANIFEST" 2>/dev/null || true)"
for p in ./agents/stage-reader.md ./agents/stage-executor.md; do
  if printf '%s\n' "$AGENTS" | grep -qxF "$p"; then pass_msg "plugin.json agents[] registers $p"; else fail_msg "plugin.json agents[] lacks $p"; fi
done
FIRST="$(jq -r '.agents[0]' "$MANIFEST" 2>/dev/null || true)"
if [ "$FIRST" = "./agents/tdd-implementer.md" ]; then pass_msg "agents[0] is still tdd-implementer"; else fail_msg "agents[0] is '$FIRST', want ./agents/tdd-implementer.md"; fi

# ---------------------------------------------------------------------------
scenario "S2: frontmatter name and exact tools lines"

check_fm() {
  local file="$1" name="$2" tools="$3" fm
  [ -f "$file" ] || { fail_msg "${file#"$ROOT"/} missing — cannot check frontmatter"; return; }
  fm="$(frontmatter "$file")"
  if printf '%s\n' "$fm" | grep -qxF "name: $name"; then pass_msg "$name: name line"; else fail_msg "$name: no 'name: $name' line"; fi
  if printf '%s\n' "$fm" | grep -qxF "tools: $tools"; then pass_msg "$name: tools line exact"; else
    fail_msg "$name: tools line is '$(printf '%s\n' "$fm" | grep '^tools:')', want 'tools: $tools'"; fi
  if printf '%s\n' "$fm" | grep -q '^description: .'; then pass_msg "$name: description line"; else fail_msg "$name: no description line"; fi
}
check_fm "$READER" stage-reader "Read, Write, Edit, Bash, Grep, Glob, Skill"
check_fm "$EXECUTOR" stage-executor "Read, Write, Edit, Bash, Grep, Glob, Skill, Agent"

# ---------------------------------------------------------------------------
scenario "S3: no model line"

for f in "$READER" "$EXECUTOR"; do
  [ -f "$f" ] || { fail_msg "${f#"$ROOT"/} missing — cannot check model"; continue; }
  if frontmatter "$f" | grep -q '^model:'; then fail_msg "${f#"$ROOT"/} pins a model: line"; else pass_msg "${f#"$ROOT"/} carries no model: line"; fi
done

# ---------------------------------------------------------------------------
scenario "S4: bodies 20..80 words"

for f in "$READER" "$EXECUTOR"; do
  [ -f "$f" ] || { fail_msg "${f#"$ROOT"/} missing — cannot count body"; continue; }
  W="$(agent_body "$f" | wc -w | tr -d ' ')"
  if [ "$W" -le 80 ] && [ "$W" -ge 20 ]; then pass_msg "${f#"$ROOT"/} body $W words in 20..80"; else fail_msg "${f#"$ROOT"/} body $W words outside 20..80"; fi
done

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
