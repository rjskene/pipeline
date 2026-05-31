#!/usr/bin/env bash
set -euo pipefail

# RED-FIRST guard for issue #700 — PATH D escalation backstop.
#
# Asserts the "abort up to a spawned B run" backstop language across two
# SKILLs. The collapsed inline D agent, if it discovers the change exceeds D's
# envelope, must ABORT UP to a spawned PATH B run; classify-issue's PATH D
# section must reference that backstop as the precondition that makes a wrong
# B→D down-route (the #707 dependency) cheap/recoverable.
#
# This spec text is NOT yet present — every assertion is expected to FAIL on
# first run for the RIGHT reason (asserted text absent).
#
# Style mirrors tests/test-path-d-auto-approve.sh: whitespace-normalized body
# + tolerant token matching, plus a windowed python3 proximity check.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTE_SKILL="$SCRIPT_DIR/../skills/execute-issue-plan/SKILL.md"
CLASSIFY_SKILL="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$EXECUTE_SKILL" "$CLASSIFY_SKILL"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: SKILL.md not found at $f" >&2
    exit 1
  fi
done

EXECUTE_BODY=$(tr '\n' ' ' < "$EXECUTE_SKILL" | tr -s '[:space:]' ' ')
CLASSIFY_BODY=$(tr '\n' ' ' < "$CLASSIFY_SKILL" | tr -s '[:space:]' ' ')

# Windowed proximity helper.
near() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
anchor = sys.argv[2]
needle = sys.argv[3]
window = int(sys.argv[4])
ok = False
for m in re.finditer(re.escape(anchor), text):
    if needle.lower() in text[m.start(): m.start() + window].lower():
        ok = True
        break
print("OK" if ok else "MISS")
PY
}

# =====================================================================
# execute-issue-plan/SKILL.md — backstop: a collapsed inline D agent that
# discovers the change exceeds D's envelope ABORTS UP to a spawned B run.
# =====================================================================

echo "execute-issue-plan/SKILL.md: D escalation backstop"

# (a) escalate / abort-up phrasing present.
inc
if printf '%s' "$EXECUTE_BODY" | grep -qiE 'escalat|abort up'; then
  pass_msg "(a) escalate / abort-up phrasing present"
else
  fail_msg "(a) execute-issue-plan/SKILL.md missing 'escalat'/'abort up' phrasing"
fi

# (b) exceeds D's envelope phrasing.
inc
if printf '%s' "$EXECUTE_BODY" | grep -qiE "exceeds (path )?d'?s? envelope|exceeds the (d )?envelope|exceeds .{0,40}envelope"; then
  pass_msg "(b) 'exceeds ... envelope' phrasing present"
else
  fail_msg "(b) execute-issue-plan/SKILL.md missing 'exceeds ... envelope' phrasing"
fi

# (c) aborts UP to a spawned B / PATH B run.
inc
if printf '%s' "$EXECUTE_BODY" | grep -qiE 'spawned (path )?b|spawned B run|PATH B'; then
  pass_msg "(c) 'spawned B' / 'PATH B' target named"
else
  fail_msg "(c) execute-issue-plan/SKILL.md missing 'spawned B'/'PATH B' escalation target"
fi

# (d) proximity: the escalation verb sits near the envelope/B-run tokens, so
# the three pieces describe a single backstop rather than scattered mentions.
inc
NEAR1=$(near "$EXECUTE_SKILL" "envelope" "escalat" 400)
NEAR2=$(near "$EXECUTE_SKILL" "envelope" "abort up" 400)
NEAR3=$(near "$EXECUTE_SKILL" "envelope" "spawned" 400)
if { [ "$NEAR1" = "OK" ] || [ "$NEAR2" = "OK" ]; } && [ "$NEAR3" = "OK" ]; then
  pass_msg "(d) escalate/abort-up + spawned both within 400 chars of 'envelope'"
else
  fail_msg "(d) backstop tokens not co-located near 'envelope' (escalat/abort-up=$NEAR1/$NEAR2, spawned=$NEAR3)"
fi

# =====================================================================
# classify-issue/SKILL.md — PATH D section references the backstop as the
# precondition making a wrong B→D down-route (the #707 dependency)
# cheap/recoverable.
# =====================================================================

echo "classify-issue/SKILL.md: PATH D references backstop as down-route safety net"

# (e) backstop reference present (escalat / abort up / backstop).
inc
if printf '%s' "$CLASSIFY_BODY" | grep -qiE 'backstop|escalat|abort up'; then
  pass_msg "(e) backstop/escalation reference present"
else
  fail_msg "(e) classify-issue/SKILL.md missing 'backstop'/'escalat'/'abort up' reference"
fi

# (f) wrong B->D down-route framing (cheap / recoverable).
inc
if printf '%s' "$CLASSIFY_BODY" | grep -qiE 'b *(→|->|to) *d|down-route' \
   && printf '%s' "$CLASSIFY_BODY" | grep -qiE 'cheap|recoverable'; then
  pass_msg "(f) wrong B→D down-route framed as cheap/recoverable"
else
  fail_msg "(f) classify-issue/SKILL.md missing 'B→D down-route ... cheap/recoverable' framing"
fi

# (g) the backstop reference lives in the PATH D section (proximity to 'PATH D').
inc
NEAR_D=$(near "$CLASSIFY_SKILL" "PATH D" "backstop" 800)
NEAR_D2=$(near "$CLASSIFY_SKILL" "PATH D" "escalat" 800)
NEAR_D3=$(near "$CLASSIFY_SKILL" "PATH D" "down-route" 800)
if [ "$NEAR_D" = "OK" ] || [ "$NEAR_D2" = "OK" ] || [ "$NEAR_D3" = "OK" ]; then
  pass_msg "(g) backstop/down-route reference sits within the PATH D section"
else
  fail_msg "(g) classify-issue/SKILL.md PATH D section missing backstop/down-route reference (backstop=$NEAR_D, escalat=$NEAR_D2, down-route=$NEAR_D3)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
