#!/bin/bash
set -uo pipefail

# Tests for hooks/permission-bridge.py — the headless permission bridge
# PermissionRequest hook (issue #1421).
#
# The hook turns an escalated permission request in a `claude -p` session into
# a file in a queue dir that an interactive operator session can watch and
# answer, instead of the session being denied outright (`--permission-prompts
# none`) or granted everything (`--dangerously-skip-permissions`).
#
# Contract:
#   - PIPELINE_PERMISSION_BRIDGE_DIR unset  -> exit 0, NOTHING on stdout.
#     This is the blast-radius invariant: the hook is registered with matcher
#     `*`, so under the dogfood install it fires in the operator's live
#     interactive sessions. Inert-without-the-knob is what makes that safe.
#   - Otherwise: write <dir>/<tool_use_id>.json (the queue file), then poll
#     <dir>/<tool_use_id>.answer until it appears or the deadline passes.
#   - `allow` / `deny [\nmessage]` in the answer file -> that behavior.
#   - timeout, malformed answer, or ANY crash -> `deny` with the skip-and-
#     continue message. An escalation the operator never saw must not be
#     silently granted.
#   - PermissionRequest does NOT honour exit 2: the hook always exits 0 and
#     expresses the decision purely through the stdout JSON envelope.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/permission-bridge.py"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

if [ ! -f "$HOOK" ]; then
  echo "ERROR: hook not found at $HOOK" >&2
  echo "Test 0: hook exists"
  inc
  fail_msg "missing $HOOK"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/logs"
printf 'PIPELINE_REPO="fake/repo"\n' > "$PROJ/pipeline.config"

# event <tool_use_id> [cwd] — a PermissionRequest event payload on stdout.
event() {
  local id="$1" cwd="${2:-$PROJ}"
  python3 - "$id" "$cwd" <<'PY'
import json, sys
print(json.dumps({
    "hook_event_name": "PermissionRequest",
    "session_id": "sess-abc123",
    "cwd": sys.argv[2],
    "tool_use_id": sys.argv[1],
    "tool_name": "Bash",
    "tool_input": {"command": "git push --force origin HEAD:main",
                   "description": "force push"},
}))
PY
}

# decision_field <key> — pull decision.<key> out of the hook envelope on stdin.
# `python3 -c`, not a heredoc: a `<<'PY'` script body would OWN stdin and the
# envelope piped in by the caller would never be read (it would silently parse
# the script text instead and every assertion would fail identically).
decision_field() { # <key>
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())["hookSpecificOutput"]["decision"]
print(d.get(sys.argv[1], ""))
' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
scenario "Case 1: PIPELINE_PERMISSION_BRIDGE_DIR unset -> rc 0, empty stdout"
# ---------------------------------------------------------------------------
OUT="$(event tu-inert | env -u PIPELINE_PERMISSION_BRIDGE_DIR \
        CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" 2>/dev/null)"
RC=$?
inc
if [ "$RC" -eq 0 ]; then
  pass_msg "1: exits 0 with the knob unset"
else
  fail_msg "1: exited $RC with the knob unset — a registered hook must be inert"
fi
inc
if [ -z "$OUT" ]; then
  pass_msg "1: emits NOTHING on stdout with the knob unset"
else
  fail_msg "1: emitted stdout with the knob unset: $(printf '%q' "$OUT")"
fi

# ---------------------------------------------------------------------------
scenario "Case 2: a pre-seeded 'allow' answer -> behavior=allow"
# ---------------------------------------------------------------------------
Q2="$WORKDIR/q2"
mkdir -p "$Q2"
printf 'allow\n' > "$Q2/tu-allow.answer"
OUT="$(event tu-allow | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q2" \
        CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" 2>/dev/null)"
RC=$?
inc
if [ "$RC" -eq 0 ]; then
  pass_msg "2: exits 0 (PermissionRequest never honours exit 2)"
else
  fail_msg "2: exited $RC"
fi
inc
if [ "$(decision_field behavior <<<"$OUT")" = "allow" ]; then
  pass_msg "2: stdout parses to behavior=allow"
else
  fail_msg "2: behavior was not allow (stdout=$(printf '%q' "$OUT"))"
fi
inc
if python3 -c '
import json,sys
o=json.loads(sys.stdin.read())["hookSpecificOutput"]
sys.exit(0 if o.get("hookEventName")=="PermissionRequest" else 1)' <<<"$OUT" 2>/dev/null; then
  pass_msg "2: envelope carries hookEventName=PermissionRequest"
else
  fail_msg "2: envelope is missing hookEventName=PermissionRequest"
fi

# ---------------------------------------------------------------------------
scenario "Case 3: 'deny' + a message line -> behavior=deny, message carried"
# ---------------------------------------------------------------------------
Q3="$WORKDIR/q3"
mkdir -p "$Q3"
printf 'deny\nnot on a real remote, operator says no\n' > "$Q3/tu-deny.answer"
OUT="$(event tu-deny | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q3" \
        CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" 2>/dev/null)"
inc
if [ "$(decision_field behavior <<<"$OUT")" = "deny" ]; then
  pass_msg "3: behavior=deny"
else
  fail_msg "3: behavior was not deny (stdout=$(printf '%q' "$OUT"))"
fi
inc
if decision_field message <<<"$OUT" | grep -qF "not on a real remote, operator says no"; then
  pass_msg "3: the operator's message is carried into the decision"
else
  fail_msg "3: the operator's message was dropped (message=$(decision_field message <<<"$OUT"))"
fi

# ---------------------------------------------------------------------------
scenario "Case 4: no answer + timeout=3 -> deny within 5 s wall"
# ---------------------------------------------------------------------------
Q4="$WORKDIR/q4"
T0=$(date +%s)
OUT="$(event tu-timeout | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q4" \
        PIPELINE_PERMISSION_BRIDGE_TIMEOUT=3 \
        CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" 2>/dev/null)"
RC=$?
T1=$(date +%s)
ELAPSED=$((T1 - T0))
inc
if [ "$(decision_field behavior <<<"$OUT")" = "deny" ]; then
  pass_msg "4: an unanswered request is denied, not allowed"
else
  fail_msg "4: behavior was not deny (stdout=$(printf '%q' "$OUT"))"
fi
inc
if [ "$ELAPSED" -le 5 ]; then
  pass_msg "4: the deny is emitted within 5 s wall (elapsed=${ELAPSED}s)"
else
  fail_msg "4: took ${ELAPSED}s with PIPELINE_PERMISSION_BRIDGE_TIMEOUT=3 — the deadline is not honoured"
fi
inc
if [ "$RC" -eq 0 ]; then
  pass_msg "4: exits 0 on timeout"
else
  fail_msg "4: exited $RC on timeout"
fi
inc
if decision_field message <<<"$OUT" | grep -qiF "do not retry"; then
  pass_msg "4: the deny message tells the session to skip and not retry"
else
  fail_msg "4: the deny message does not carry the skip-and-continue instruction"
fi

# ---------------------------------------------------------------------------
scenario "Case 5: a malformed answer -> behavior=deny (never a silent allow)"
# ---------------------------------------------------------------------------
Q5="$WORKDIR/q5"
mkdir -p "$Q5"
printf 'maybe later\n' > "$Q5/tu-bad.answer"
OUT="$(event tu-bad | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q5" \
        PIPELINE_PERMISSION_BRIDGE_TIMEOUT=3 \
        CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" 2>/dev/null)"
inc
if [ "$(decision_field behavior <<<"$OUT")" = "deny" ]; then
  pass_msg "5: a malformed answer denies"
else
  fail_msg "5: a malformed answer did not deny (stdout=$(printf '%q' "$OUT"))"
fi

# ---------------------------------------------------------------------------
scenario "Case 6: the queue file carries the seven operator-facing keys"
# ---------------------------------------------------------------------------
Q6="$WORKDIR/q6"
WT="$WORKDIR/wt-1421-headless-permission-bridge"
mkdir -p "$WT"
printf 'allow\n' > "$WORKDIR/seed"
mkdir -p "$Q6"
cp "$WORKDIR/seed" "$Q6/tu-queue.answer"
event tu-queue "$WT" | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q6" \
  CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" >/dev/null 2>&1
inc
if [ -f "$Q6/tu-queue.json" ]; then
  pass_msg "6: the queue file <dir>/<tool_use_id>.json exists after the run"
else
  fail_msg "6: no queue file at $Q6/tu-queue.json — the operator has nothing to read"
fi
for key in id ts session_id cwd tool_name tool_input issue; do
  inc
  if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in d else 1)' "$Q6/tu-queue.json" "$key" 2>/dev/null; then
    pass_msg "6: queue file carries key '$key'"
  else
    fail_msg "6: queue file is missing key '$key'"
  fi
done
inc
if [ "$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1])).get("issue",""))' "$Q6/tu-queue.json" 2>/dev/null)" = "#1421" ]; then
  pass_msg "6: issue= is derived from the wt-<N>-<slug> cwd basename (#1421)"
else
  fail_msg "6: issue= was not derived from the worktree basename"
fi
inc
if [ ! -e "$Q6/tu-queue.json.tmp" ] && [ -z "$(find "$Q6" -name '*.tmp' -print -quit)" ]; then
  pass_msg "6: the queue file is written atomically (no .tmp left behind)"
else
  fail_msg "6: a .tmp partial write was left in the queue dir"
fi

# ---------------------------------------------------------------------------
scenario "Case 7: a non-worktree cwd yields an empty issue, not a guess"
# ---------------------------------------------------------------------------
Q7="$WORKDIR/q7"
mkdir -p "$Q7"
printf 'allow\n' > "$Q7/tu-noissue.answer"
event tu-noissue "$PROJ" | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q7" \
  CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" >/dev/null 2>&1
inc
if [ "$(python3 -c '
import json,sys
print(repr(json.load(open(sys.argv[1])).get("issue","MISSING")))' "$Q7/tu-noissue.json" 2>/dev/null)" = "''" ]; then
  pass_msg "7: a cwd that is not wt-<N>[-<slug>] yields issue=''"
else
  fail_msg "7: issue= was guessed from a non-worktree cwd"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
