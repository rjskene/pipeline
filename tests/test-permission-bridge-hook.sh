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

# ---------------------------------------------------------------------------
scenario "Case 8: a real event carries NO tool_use_id — the id stays legible"
# ---------------------------------------------------------------------------
# Measured against claude 2.1.278 in the #1421 spike: the PermissionRequest
# payload is {session_id, transcript_path, cwd, prompt_id, permission_mode,
# effort, hook_event_name, tool_name, tool_input, permission_suggestions} —
# there is NO tool_use_id. The fallback id must therefore be (a) unique per
# call, so two escalations in one prompt cannot collide on one queue file, and
# (b) correlatable back to the session the operator is watching. `req-` prefixed
# and carrying the session-id head does both; `tool_use_id` stays PREFERRED so
# the naming follows the harness if the field is ever added.
Q8="$WORKDIR/q8"
mkdir -p "$Q8"
printf '{"hook_event_name":"PermissionRequest","session_id":"91699b82-23f0-429a-9c41-e2c90ae3b056","cwd":"%s","prompt_id":"e6d27137","tool_name":"Bash","tool_input":{"command":"sudo -n id"}}' "$PROJ" \
  | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q8" PIPELINE_PERMISSION_BRIDGE_TIMEOUT=2 \
    CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" >/dev/null 2>&1
Q8_FILES="$(find "$Q8" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null)"
inc
if [ "$(printf '%s\n' "$Q8_FILES" | grep -c .)" -eq 1 ]; then
  pass_msg "8: an event with no tool_use_id still produces exactly one queue file"
else
  fail_msg "8: expected one queue file, got: $(printf '%s' "$Q8_FILES" | tr '\n' ' ')"
fi
inc
case "$Q8_FILES" in
  req-91699b82-*) pass_msg "8: the fallback id is 'req-<session-head>-<ms>' ($Q8_FILES)" ;;
  *)              fail_msg "8: the fallback id is not correlatable to the session ($Q8_FILES)" ;;
esac
# Two escalations inside ONE prompt must not land on the same queue file.
printf '{"hook_event_name":"PermissionRequest","session_id":"91699b82-23f0-429a-9c41-e2c90ae3b056","cwd":"%s","prompt_id":"e6d27137","tool_name":"Bash","tool_input":{"command":"chmod -R 777 /tmp"}}' "$PROJ" \
  | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q8" PIPELINE_PERMISSION_BRIDGE_TIMEOUT=2 \
    CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" >/dev/null 2>&1
inc
if [ "$(find "$Q8" -maxdepth 1 -name '*.json' | wc -l)" -eq 2 ]; then
  pass_msg "8: a second escalation in the same prompt gets its OWN queue file"
else
  fail_msg "8: two escalations collided on one queue file — one would be unanswerable"
fi

# ---------------------------------------------------------------------------
scenario "Case 9: a non-PermissionRequest payload is inert — no queue file, no wait"
# ---------------------------------------------------------------------------
# The #1426 stall: tests/test-subagent-log-utils-win32.sh execs every hook in
# hooks/ with a NON-PermissionRequest payload (or none at all). Inside a
# bridge-armed session that exec inherited PIPELINE_PERMISSION_BRIDGE_DIR, so the
# hook queued a `tool_name=""` garbage request and then blocked for the full
# bridge timeout (840 s live) waiting for an answer no operator was expecting.
# The gate: require hook_event_name == "PermissionRequest" AND a non-empty
# tool_name before touching the queue. Anything else exits 0 with EMPTY stdout —
# the same "expressed no opinion" semantics as the env-inertness gate in Case 1,
# never a deny envelope: emitting a decision for an event class that does not
# consume one would fabricate a verdict. "Anything else" includes valid JSON that
# is not an OBJECT: `read_event_stdin()` returns it verbatim, and a truthy
# non-dict (a bare string or number) makes `.get()` raise, which without a type
# check lands on the module-level crash handler and emits a `deny` envelope plus a
# traceback in the error log for an event that was never an escalation.
Q9="$WORKDIR/q9"
P9_LABELS=(
  "empty stdin"
  "no hook_event_name"
  "PreToolUse-shaped payload"
  "PermissionRequest with an empty tool_name (#1426 wire shape)"
  "valid JSON that is not an object (string)"
  "valid JSON that is not an object (number)"
)
P9_PAYLOADS=(
  ''
  '{"tool_name":"Bash","tool_input":{}}'
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
  '{"hook_event_name":"PermissionRequest","tool_name":"","tool_input":{},"session_id":""}'
  '"not an object"'
  '5'
)
T0=$(date +%s)
for i in "${!P9_PAYLOADS[@]}"; do
  OUT="$(printf '%s' "${P9_PAYLOADS[$i]}" | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q9" \
          PIPELINE_PERMISSION_BRIDGE_TIMEOUT=3 \
          CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" 2>/dev/null)"
  RC=$?
  inc
  if [ "$RC" -eq 0 ]; then
    pass_msg "9: ${P9_LABELS[$i]} -> exits 0"
  else
    fail_msg "9: ${P9_LABELS[$i]} -> exited $RC"
  fi
  inc
  if [ -z "$OUT" ]; then
    pass_msg "9: ${P9_LABELS[$i]} -> emits NOTHING on stdout (no deny envelope)"
  else
    fail_msg "9: ${P9_LABELS[$i]} -> emitted stdout: $(printf '%q' "$OUT")"
  fi
done
T1=$(date +%s)
ELAPSED=$((T1 - T0))
inc
Q9_FILES="$(find "$Q9" -maxdepth 1 -name '*.json' 2>/dev/null)"
if [ "$(printf '%s' "$Q9_FILES" | grep -c . )" -eq 0 ]; then
  pass_msg "9: no queue file is written for any non-PermissionRequest payload"
else
  fail_msg "9: a malformed payload was queued: $(printf '%s' "$Q9_FILES" | tr '\n' ' ')"
fi
inc
# With PIPELINE_PERMISSION_BRIDGE_TIMEOUT=3 an UNGATED hook burns ~3 s for each of
# the four OBJECT-shaped sub-cases (the two non-object ones raise instead), so a
# 5 s ceiling discriminates gated from ungated without being flaky on a loaded
# host.
if [ "$ELAPSED" -le 5 ]; then
  pass_msg "9: every shape resolves without waiting (elapsed=${ELAPSED}s)"
else
  fail_msg "9: took ${ELAPSED}s for the inert payloads — the hook still enters the answer poll"
fi

# ---------------------------------------------------------------------------
scenario "Case 10: a camelCase payload queues with tool_name populated"
# ---------------------------------------------------------------------------
# The #1426 gate accepts BOTH key spellings (hook_event_name/hookEventName,
# tool_name/toolName), mirroring queue_id()'s tool_use_id/toolUseId tolerance. The
# queue WRITER has to be equally tolerant, or a camelCase escalation passes the
# gate, blocks for the full timeout as a REAL escalation, and yet records
# tool_name="" — which `pending` renders `tool=(malformed)`, i.e. exactly the label
# the operator notes say to `deny` as a dead pre-gate artifact. A live escalation
# must never be presented to the operator as junk. Post-gate, `tool` is guaranteed
# non-empty, so the queue file can always name the tool.
Q10="$WORKDIR/q10"
mkdir -p "$Q10"
printf '{"hookEventName":"PermissionRequest","session_id":"sess-camel","cwd":"%s","toolName":"Bash","tool_input":{"command":"sudo -n id"}}' "$PROJ" \
  | env PIPELINE_PERMISSION_BRIDGE_DIR="$Q10" PIPELINE_PERMISSION_BRIDGE_TIMEOUT=2 \
    CLAUDE_PROJECT_DIR="$PROJ" python3 "$HOOK" >/dev/null 2>&1
Q10_FILE="$(find "$Q10" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null)"
inc
if [ -n "$Q10_FILE" ]; then
  pass_msg "10: a camelCase PermissionRequest is queued (the gate accepts the spelling)"
else
  fail_msg "10: a camelCase PermissionRequest was not queued at all"
fi
inc
Q10_TOOL="$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1])).get("tool_name","MISSING"))' "$Q10_FILE" 2>/dev/null)"
if [ "$Q10_TOOL" = "Bash" ]; then
  pass_msg "10: the queue file records tool_name=Bash, so pending cannot mislabel it (malformed)"
else
  fail_msg "10: the queue file recorded tool_name='$Q10_TOOL' — a live escalation renders as tool=(malformed)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
