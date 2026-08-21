#!/usr/bin/env bash
# test-evaluate-pr-capability-refusal-prose.sh — #1233 "a contract needs a
# listener" invariants.
#
# #1225 landed the CAPABILITY-REFUSED: contract in agents/tdd-implementer.md as
# PROSE ONLY. No hook, gate, or CI check grepped for the token, so an executor
# that silently substituted still merged. These are the static greps that pin
# the listener into place: the detector exists, the gate token is enumerated
# everywhere the other block-* tokens are, the eval-time caller threads the
# source knob, the knob is allowlisted, and the capture semantics + coverage
# hole are documented.
#
# Static-only: reads tracked sources, runs nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EVAL_SKILL="$ROOT/skills/evaluate-issue-pr/SKILL.md"
FULLSEND_SKILL="$ROOT/skills/fullsend/SKILL.md"
GATE="$ROOT/scripts/auto-merge-gate.sh"
RUN_QUEUE="$ROOT/scripts/run-queue.sh"
ALLOWLIST="$ROOT/tests/config-drift-allowlist.txt"
DETECTOR="$ROOT/scripts/check-capability-refusal.sh"
OBSERVABILITY="$ROOT/docs/observability.md"

TOKEN="block-capability-refused"
KNOB="PIPELINE_CAPABILITY_REFUSAL_SOURCES"

FAILED=0
fail() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
pass() { echo "  PASS: $*"; }

require_file() {
  if [ -f "$1" ]; then
    return 0
  fi
  fail "$2: $1 does not exist"
  return 1
}

# min_distance <file> <patternA> <patternB> — smallest |lineA - lineB| over all
# matching line pairs; prints 999999 when either side has no match.
min_distance() {
  local file="$1" a="$2" b="$3"
  A_PAT="$a" B_PAT="$b" python3 - "$file" <<'PY'
import os, sys
a = os.environ["A_PAT"]
b = os.environ["B_PAT"]
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
al = [i for i, l in enumerate(lines) if a in l]
bl = [i for i, l in enumerate(lines) if b in l]
print(min((abs(x - y) for x in al for y in bl), default=999999))
PY
}

# region_after <file> <marker> — prints every line at or after the first line
# containing <marker>.
region_after() {
  local file="$1" marker="$2"
  MARKER="$marker" python3 - "$file" <<'PY'
import os, sys
marker = os.environ["MARKER"]
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
for i, l in enumerate(lines):
    if marker in l:
        sys.stdout.write("\n".join(lines[i:]))
        break
PY
}

# comment_bullet_block <file> <marker> — from the header-comment bullet line
# containing <marker> up to (not including) the next `- ` comment bullet.
comment_bullet_block() {
  local file="$1" marker="$2"
  MARKER="$marker" python3 - "$file" <<'PY'
import os, re, sys
marker = os.environ["MARKER"]
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
out, started = [], False
bullet = re.compile(r'^#\s+-\s')
for l in lines:
    if not started:
        if marker in l:
            started = True
            out.append(l)
        continue
    if bullet.match(l):
        break
    if not l.startswith("#"):
        break
    out.append(l)
sys.stdout.write("\n".join(out))
PY
}

echo "=== (a) evaluate-issue-pr Step 11.2 token enumeration ==="
if require_file "$EVAL_SKILL" "(a)"; then
  A_LINE="$(grep -F 'Prints exactly one token' "$EVAL_SKILL" | head -1)"
  if [ -z "$A_LINE" ]; then
    fail "(a) no 'Prints exactly one token' enumeration found in $EVAL_SKILL"
  elif printf '%s' "$A_LINE" | grep -qF "$TOKEN"; then
    pass "(a) the token enumeration lists $TOKEN"
  else
    fail "(a) 'Prints exactly one token' enumeration does not list $TOKEN"
  fi
fi

echo "=== (b) Step 11.2 threads $KNOB at the auto_merge_should_fire call site ==="
if require_file "$EVAL_SKILL" "(b)"; then
  B_DIST="$(min_distance "$EVAL_SKILL" 'auto_merge_should_fire' "$KNOB")"
  if [ "$B_DIST" -le 15 ] 2>/dev/null; then
    pass "(b) $KNOB is threaded within $B_DIST line(s) of an auto_merge_should_fire call"
  else
    fail "(b) $KNOB is not threaded at the auto_merge_should_fire call site (min distance $B_DIST)"
  fi
fi

echo "=== (c) fullsend: the token appears in ALL THREE enumerations ==="
if require_file "$FULLSEND_SKILL" "(c)"; then
  C_LINES="$(grep -cF "$TOKEN" "$FULLSEND_SKILL" 2>/dev/null || true)"
  if [ "$C_LINES" -ge 3 ] 2>/dev/null; then
    pass "(c) $TOKEN appears on $C_LINES distinct lines (>= 3)"
  else
    fail "(c) $TOKEN appears on $C_LINES distinct line(s), expected >= 3"
  fi
  if grep -F "$TOKEN" "$FULLSEND_SKILL" | grep -qF 'Tokens:'; then
    pass "(c) greenlight Tokens: enumeration lists the token"
  else
    fail "(c) the greenlight 'Tokens:' enumeration does not list $TOKEN"
  fi
  if grep -F "$TOKEN" "$FULLSEND_SKILL" | grep -qF 'reason='; then
    pass "(c) the agent-finished reason= field list lists the token"
  else
    fail "(c) the 'reason=' field list does not list $TOKEN"
  fi
  if grep -F "$TOKEN" "$FULLSEND_SKILL" | grep -qF 'Hard block'; then
    pass "(c) the wave-halt Hard block list lists the token"
  else
    fail "(c) the 'Hard block' list does not list $TOKEN"
  fi
fi

echo "=== (d) auto-merge-gate.sh header: Tokens list AND Order line ==="
if require_file "$GATE" "(d)"; then
  D_TOKENS="$(comment_bullet_block "$GATE" '- Tokens:')"
  D_ORDER="$(comment_bullet_block "$GATE" '- Order:')"
  if [ -z "$D_TOKENS" ]; then
    fail "(d) no '- Tokens:' header bullet found in $GATE"
  elif printf '%s' "$D_TOKENS" | grep -qF "$TOKEN"; then
    pass "(d) header Tokens list enumerates $TOKEN"
  else
    fail "(d) header Tokens list does not enumerate $TOKEN"
  fi
  if [ -z "$D_ORDER" ]; then
    fail "(d) no '- Order:' header bullet found in $GATE"
  elif printf '%s' "$D_ORDER" | grep -qF "$TOKEN"; then
    pass "(d) header Order line enumerates $TOKEN"
  else
    fail "(d) header Order line does not enumerate $TOKEN"
  fi
fi

echo "=== (e) config-drift allowlist declares the knob ==="
if require_file "$ALLOWLIST" "(e)"; then
  if grep -qF "$KNOB" "$ALLOWLIST"; then
    pass "(e) $ALLOWLIST declares $KNOB"
  else
    fail "(e) $ALLOWLIST does not declare $KNOB"
  fi
fi

echo "=== (f) the detector exists and is syntactically valid ==="
if [ ! -f "$DETECTOR" ]; then
  fail "(f) scripts/check-capability-refusal.sh does not exist"
elif bash -n "$DETECTOR" 2>/dev/null; then
  pass "(f) scripts/check-capability-refusal.sh exists and passes bash -n"
else
  fail "(f) scripts/check-capability-refusal.sh fails bash -n"
fi

echo "=== (g) run-queue.sh extract_block_reason header enumerates the token ==="
if require_file "$RUN_QUEUE" "(g)"; then
  G_DIST="$(min_distance "$RUN_QUEUE" 'extract_block_reason() {' "$TOKEN")"
  if [ "$G_DIST" -le 20 ] 2>/dev/null; then
    pass "(g) $TOKEN is enumerated within $G_DIST line(s) of extract_block_reason()"
  else
    fail "(g) extract_block_reason()'s header comment does not enumerate $TOKEN (min distance $G_DIST)"
  fi
fi

echo "=== (h) docs/observability.md documents capture + the async hole ==="
if require_file "$OBSERVABILITY" "(h)"; then
  H_SECTION="$(MARKER='## Subagent log' python3 - "$OBSERVABILITY" <<'PY'
import os, sys
marker = os.environ["MARKER"]
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
out, started = [], False
for l in lines:
    if not started:
        if l.strip() == marker:
            started = True
        continue
    if l.startswith("## "):
        break
    out.append(l)
sys.stdout.write("\n".join(out))
PY
)"
  if [ -z "$H_SECTION" ]; then
    fail "(h) no '## Subagent log' section found in $OBSERVABILITY"
  else
    if printf '%s' "$H_SECTION" | grep -qF 'content'; then
      pass "(h) the section states the leaf text is sourced from the PostToolUse content blocks"
    else
      fail "(h) the '## Subagent log' section never mentions the 'content' blocks capture source"
    fi
    if printf '%s' "$H_SECTION" | grep -qF 'async_launched'; then
      pass "(h) the section names the async_launched coverage hole"
    else
      fail "(h) the '## Subagent log' section never names the async_launched coverage hole"
    fi
  fi
fi

echo "=== (i) Step 11.4 names the re-dispatch remediation for the token ==="
if require_file "$EVAL_SKILL" "(i)"; then
  I_REGION="$(region_after "$EVAL_SKILL" 'On any `block-*` reason')"
  if [ -z "$I_REGION" ]; then
    fail "(i) Step 11.4 ('On any \`block-*\` reason') not found in $EVAL_SKILL"
  else
    if printf '%s' "$I_REGION" | grep -qF "$TOKEN"; then
      pass "(i) Step 11.4 names $TOKEN"
    else
      fail "(i) Step 11.4 does not name $TOKEN"
    fi
    if printf '%s' "$I_REGION" | grep -qiF 're-dispatch'; then
      pass "(i) Step 11.4 names the re-dispatch remediation"
    else
      fail "(i) Step 11.4 does not name the re-dispatch remediation"
    fi
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
