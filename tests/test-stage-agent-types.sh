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
#   S5  zero general-purpose stage dispatches left in fullsend + dispatch-routing
#   S6  every full stage-typed shape in dispatch-routing carries the absolute
#       SKILL.md path and a description matching its type (>= 7 shapes)
#   S7  execute-issue-plan names pipeline:stage-executor
#   S8  left-alone guard: pre-PR reviewer and analyze-issues keep general-purpose
#   S9  negative controls for the S5 matcher and the S6 path check

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FULLSEND="$ROOT/skills/fullsend/SKILL.md"
ROUTING="$ROOT/skills/fullsend/references/dispatch-routing.md"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
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

# ---------------------------------------------------------------------------
scenario "S5: zero general-purpose stage dispatches"

GP_RE="subagent_type[[:space:]]*[:=][[:space:]]*['\"]?general-purpose|Agent\(general-purpose"
gp_hits() { grep -nE "$GP_RE" "$@" 2>/dev/null || true; }
for f in "$FULLSEND" "$ROUTING"; do
  H="$(gp_hits "$f")"
  if [ -z "$H" ]; then pass_msg "${f#"$ROOT"/}: zero general-purpose dispatch shapes"; else
    fail_msg "${f#"$ROOT"/}: general-purpose dispatch shape(s): $(printf '%s\n' "$H" | cut -c1-120 | tr '\n' ' ')"; fi
done

# ---------------------------------------------------------------------------
scenario "S6: stage-typed shapes carry the absolute SKILL.md path"

# stage_blocks <file> -> one shape per line: from `Agent(subagent_type='pipeline:stage-*'`
# to its closing `')`. Lines carrying the `, ...)` prose shorthand are skipped —
# they have no closing `')` and would swallow the next shape.
stage_blocks() {
  awk '
    function flush(t,  k) { k = index(t, "\x27)"); if (k) { print substr(t, 1, k + 1); return 1 } return 0 }
    inb { buf = buf " " $0; if (flush(buf)) inb = 0; next }
    {
      i = match($0, /Agent\(subagent_type=\x27pipeline:stage-(reader|executor)\x27/)
      if (!i || index($0, ", ...)")) next
      buf = substr($0, i)
      if (!flush(buf)) inb = 1
    }
  ' "$1"
}

# check_blocks <file> -> prints one problem line per bad shape; prints COUNT=<n> last
check_blocks() {
  local n=0 b d
  while IFS= read -r b; do
    n=$((n + 1))
    case "$b" in
      *'${CLAUDE_PLUGIN_ROOT}/skills/'*'/SKILL.md'*) ;;
      *) echo "no absolute SKILL.md path: $(printf '%s' "$b" | cut -c1-100)" ;;
    esac
    d="$(printf '%s' "$b" | sed -nE "s/.*description='([^']*)'.*/\1/p")"
    case "$b" in
      *pipeline:stage-reader*)
        case "$d" in "plan-issue #"*|"evaluate-issue-plan #"*|"evaluate-issue-pr #"*) ;; *) echo "stage-reader description '$d'" ;; esac ;;
      *pipeline:stage-executor*)
        case "$d" in "execute-issue-plan #"*) ;; *) echo "stage-executor description '$d'" ;; esac ;;
    esac
  done < <(stage_blocks "$1")
  echo "COUNT=$n"
}

OUT="$(check_blocks "$ROUTING")"
CNT="$(printf '%s\n' "$OUT" | sed -n 's/^COUNT=//p')"
BAD="$(printf '%s\n' "$OUT" | grep -v '^COUNT=' || true)"
if [ "${CNT:-0}" -ge 7 ]; then pass_msg "dispatch-routing: $CNT stage-typed shapes (>= 7)"; else fail_msg "dispatch-routing: ${CNT:-0} stage-typed shapes, want >= 7"; fi
if [ -z "$BAD" ]; then pass_msg "every stage-typed shape carries the SKILL.md path and a matching description"; else
  fail_msg "bad stage shape(s): $(printf '%s\n' "$BAD" | tr '\n' ';')"; fi

# ---------------------------------------------------------------------------
scenario "S7: execute-issue-plan names the stage-executor type"

EIP="$ROOT/skills/execute-issue-plan/SKILL.md"
if grep -qF 'pipeline:stage-executor' "$EIP"; then pass_msg "execute-issue-plan names pipeline:stage-executor"; else fail_msg "execute-issue-plan lacks pipeline:stage-executor"; fi
if grep -qF 'One `general-purpose` agent' "$EIP"; then fail_msg "execute-issue-plan still says One \`general-purpose\` agent"; else pass_msg "execute-issue-plan dropped One \`general-purpose\` agent"; fi

# ---------------------------------------------------------------------------
scenario "S8: left-alone general-purpose sites"

for f in "$ROOT/skills/execute-issue-plan/references/pre-pr-review-loop.md" "$ROOT/skills/analyze-issues/SKILL.md"; do
  if grep -qF 'general-purpose' "$f"; then pass_msg "${f#"$ROOT"/} still names general-purpose"; else fail_msg "${f#"$ROOT"/} lost general-purpose"; fi
done

# ---------------------------------------------------------------------------
scenario "S9: negative controls"

FX="$TMPD/fixture.md"
printf '%s\n' "     Agent(subagent_type='general-purpose', model='opus', description='plan-issue #<N>', prompt: 'x')" > "$FX"
if [ -n "$(gp_hits "$FX")" ]; then pass_msg "S5 matcher fires on a general-purpose fixture"; else fail_msg "S5 matcher missed a general-purpose fixture"; fi
printf '%s\n' "     Agent(subagent_type='pipeline:stage-reader'," "           description='plan-issue #<N>'," "           prompt: 'then follow skills/plan-issue/SKILL.md')" > "$FX"
OUT="$(check_blocks "$FX")"
if printf '%s\n' "$OUT" | grep -q 'no absolute SKILL.md path'; then pass_msg "S6 path check fires on a shape lacking \${CLAUDE_PLUGIN_ROOT}"; else fail_msg "S6 path check missed a relative-path fixture: $OUT"; fi
printf '%s\n' "     Agent(subagent_type='pipeline:stage-executor', description='evaluate-issue-pr #<N>', prompt: 'follow \${CLAUDE_PLUGIN_ROOT}/skills/evaluate-issue-pr/SKILL.md')" > "$FX"
OUT="$(check_blocks "$FX")"
if printf '%s\n' "$OUT" | grep -q 'stage-executor description'; then pass_msg "S6 description check fires on a mistyped shape"; else fail_msg "S6 description check missed a mistyped fixture: $OUT"; fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
