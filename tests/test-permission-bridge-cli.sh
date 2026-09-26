#!/bin/bash
set -uo pipefail

# Tests for scripts/permission-bridge.sh — the operator-side CLI of the
# headless permission bridge (issue #1421).
#
# The hook (hooks/permission-bridge.py) writes `<dir>/<id>.json` and blocks
# polling for `<dir>/<id>.answer`. This script is the only thing an operator
# needs in the loop:
#
#   pending                     — one line per UNANSWERED request
#   show <id>                   — the queue file verbatim
#   answer <id> allow|deny [m]  — write the answer file (atomically)
#   prune                       — drop answered pairs older than a day
#
# Queue dir resolution: PIPELINE_PERMISSION_BRIDGE_DIR, else
# ${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/scratch/permission-queue.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SCRIPT_DIR/../scripts/permission-bridge.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

if [ ! -f "$CLI" ]; then
  echo "ERROR: $CLI: No such file or directory" >&2
  echo "Test 0: CLI exists"
  inc
  fail_msg "missing $CLI"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

Q="$WORKDIR/queue"
mkdir -p "$Q"

# seed <id> <issue> <tool> <command>
seed() {
  python3 -c '
import json, sys
p, qid, issue, tool, cmd = sys.argv[1:6]
json.dump({"id": qid, "ts": "2026-09-26T00:00:00Z", "session_id": "sess-1",
           "cwd": "/tmp/wt", "tool_name": tool,
           "tool_input": {"command": cmd}, "issue": issue},
          open(p, "w"), indent=2, sort_keys=True)
' "$Q/$1.json" "$1" "$2" "$3" "$4"
}

# run <args...> — capture stdout in OUT, stderr in ERR, rc in RC.
OUT=""; ERR=""; RC=0
run() {
  local eout="$WORKDIR/.eout"
  OUT="$(PIPELINE_PERMISSION_BRIDGE_DIR="$Q" bash "$CLI" "$@" 2>"$eout")"
  RC=$?
  ERR="$(cat "$eout")"
}

LONG_CMD="git push --force https://example.invalid/a/very/long/remote/url/that/keeps/going/and/going/and/going.git HEAD:main"

seed q-open  "#1421" Bash "$LONG_CMD"
seed q-done  "#1400" Write "docs/x.md"
printf 'allow\n' > "$Q/q-done.answer"

# ---------------------------------------------------------------------------
scenario "pending: only UNANSWERED requests, one line each"
# ---------------------------------------------------------------------------
run pending
inc
if [ "$RC" -eq 0 ]; then
  pass_msg "pending exits 0"
else
  fail_msg "pending exited $RC (stderr=$ERR)"
fi
inc
if grep -qF 'q-open' <<<"$OUT"; then
  pass_msg "pending lists the unanswered request"
else
  fail_msg "pending does not list the unanswered request (out=$(printf '%q' "$OUT"))"
fi
inc
if grep -qF 'q-done' <<<"$OUT"; then
  fail_msg "pending listed an ANSWERED request — the operator would answer it twice"
else
  pass_msg "pending hides a request that already has a sibling .answer"
fi
inc
if [ "$(grep -c . <<<"$OUT")" -eq 1 ]; then
  pass_msg "pending prints exactly one line for one pending request"
else
  fail_msg "pending printed $(grep -c . <<<"$OUT") lines for one pending request"
fi
inc
if grep -qF '#1421' <<<"$OUT"; then
  pass_msg "the pending line carries the issue"
else
  fail_msg "the pending line does not carry the issue"
fi
inc
if grep -qF 'Bash' <<<"$OUT"; then
  pass_msg "the pending line carries the tool name"
else
  fail_msg "the pending line does not carry the tool name"
fi
PREVIEW="$(sed -n 's/.*input=//p' <<<"$OUT")"
inc
if [ -n "$PREVIEW" ]; then
  pass_msg "the pending line carries an input= preview"
else
  fail_msg "the pending line carries no input= preview"
fi
inc
if [ "${#PREVIEW}" -le 80 ]; then
  pass_msg "the input= preview is capped at 80 chars (len=${#PREVIEW})"
else
  fail_msg "the input= preview is ${#PREVIEW} chars — the cap is 80"
fi
inc
if grep -qF 'git push --force' <<<"$PREVIEW"; then
  pass_msg "the preview is the HEAD of the input, not a hash"
else
  fail_msg "the preview does not show the start of the tool input"
fi

# ---------------------------------------------------------------------------
scenario "pending: an empty or missing queue dir prints nothing and exits 0"
# ---------------------------------------------------------------------------
EMPTY="$WORKDIR/empty"; mkdir -p "$EMPTY"
OUT="$(PIPELINE_PERMISSION_BRIDGE_DIR="$EMPTY" bash "$CLI" pending 2>&1)"; RC=$?
inc
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass_msg "pending on an EMPTY dir prints nothing, exits 0"
else
  fail_msg "pending on an empty dir: rc=$RC out=$(printf '%q' "$OUT")"
fi
OUT="$(PIPELINE_PERMISSION_BRIDGE_DIR="$WORKDIR/nope" bash "$CLI" pending 2>&1)"; RC=$?
inc
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass_msg "pending on a MISSING dir prints nothing, exits 0 (the watch loop never errors)"
else
  fail_msg "pending on a missing dir: rc=$RC out=$(printf '%q' "$OUT")"
fi

# ---------------------------------------------------------------------------
scenario "show: verbatim queue file; unknown id is an error"
# ---------------------------------------------------------------------------
run show q-open
inc
if [ "$RC" -eq 0 ] && [ "$OUT" = "$(cat "$Q/q-open.json")" ]; then
  pass_msg "show <id> emits the queue file verbatim"
else
  fail_msg "show <id> did not emit the queue file verbatim (rc=$RC)"
fi
run show q-nosuch
inc
if [ "$RC" -ne 0 ]; then
  pass_msg "show on an unknown id exits non-zero (rc=$RC)"
else
  fail_msg "show on an unknown id exited 0"
fi
inc
if [ -n "$ERR" ]; then
  pass_msg "show on an unknown id explains itself on stderr"
else
  fail_msg "show on an unknown id said nothing on stderr"
fi

# ---------------------------------------------------------------------------
scenario "answer: allow / deny+message / rejected verdict"
# ---------------------------------------------------------------------------
run answer q-open allow
inc
if [ "$RC" -eq 0 ]; then
  pass_msg "answer <id> allow exits 0"
else
  fail_msg "answer <id> allow exited $RC (stderr=$ERR)"
fi
inc
if [ "$(head -1 "$Q/q-open.answer" 2>/dev/null)" = "allow" ]; then
  pass_msg "answer <id> allow writes an answer file whose FIRST LINE is allow"
else
  fail_msg "answer <id> allow did not write 'allow' as the first line"
fi
inc
if [ -z "$(find "$Q" -name '*.tmp' -print -quit)" ]; then
  pass_msg "the answer file is moved into place — no .tmp partial left behind"
else
  fail_msg "a .tmp partial write was left in the queue dir (the hook can read a half-written answer)"
fi
inc
run pending
if grep -qF 'q-open' <<<"$OUT"; then
  fail_msg "an answered request is still pending"
else
  pass_msg "an answered request drops off pending"
fi

seed q-deny "#1402" Bash "rm -rf /"
run answer q-deny deny "not on my watch"
inc
if [ "$(head -1 "$Q/q-deny.answer" 2>/dev/null)" = "deny" ]; then
  pass_msg "answer <id> deny writes deny on the first line"
else
  fail_msg "answer <id> deny did not write 'deny' on the first line"
fi
inc
if [ "$(sed -n '2p' "$Q/q-deny.answer" 2>/dev/null)" = "not on my watch" ]; then
  pass_msg "the operator message lands on line 2 (deny\\nmsg)"
else
  fail_msg "the operator message is not on line 2 (got: $(sed -n '2p' "$Q/q-deny.answer" 2>/dev/null))"
fi

seed q-bad "#1403" Bash "curl example.invalid"
run answer q-bad maybe
inc
if [ "$RC" -ne 0 ]; then
  pass_msg "answer <id> maybe is rejected (rc=$RC)"
else
  fail_msg "answer <id> maybe was accepted — only allow/deny are verdicts"
fi
inc
if [ ! -e "$Q/q-bad.answer" ]; then
  pass_msg "a rejected verdict writes NO answer file"
else
  fail_msg "a rejected verdict still wrote an answer file"
fi

run answer q-nosuch allow
inc
if [ "$RC" -ne 0 ] && [ ! -e "$Q/q-nosuch.answer" ]; then
  pass_msg "answer on an unknown id is refused, nothing written"
else
  fail_msg "answer on an unknown id: rc=$RC, answer file exists=$([ -e "$Q/q-nosuch.answer" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
scenario "prune: answered + older than a day only"
# ---------------------------------------------------------------------------
PQ="$WORKDIR/prune"; mkdir -p "$PQ"
mk() { # <id> <answered:0|1> <age-days>
  printf '{"id":"%s"}\n' "$1" > "$PQ/$1.json"
  [ "$2" = 1 ] && printf 'allow\n' > "$PQ/$1.answer"
  if [ "$3" != 0 ]; then
    touch -d "$3 days ago" "$PQ/$1.json" 2>/dev/null
    [ "$2" = 1 ] && touch -d "$3 days ago" "$PQ/$1.answer" 2>/dev/null
  fi
  return 0
}
mk old-answered   1 3
mk young-answered 1 0
mk old-unanswered 0 3
OUT="$(PIPELINE_PERMISSION_BRIDGE_DIR="$PQ" bash "$CLI" prune 2>&1)"; RC=$?
inc
if [ "$RC" -eq 0 ]; then
  pass_msg "prune exits 0"
else
  fail_msg "prune exited $RC ($OUT)"
fi
inc
if [ ! -e "$PQ/old-answered.json" ] && [ ! -e "$PQ/old-answered.answer" ]; then
  pass_msg "prune deletes the answered pair older than a day"
else
  fail_msg "prune left the stale answered pair behind"
fi
inc
if [ -e "$PQ/young-answered.json" ] && [ -e "$PQ/young-answered.answer" ]; then
  pass_msg "prune keeps a YOUNGER answered pair (a live run's evidence)"
else
  fail_msg "prune deleted a younger answered pair"
fi
inc
if [ -e "$PQ/old-unanswered.json" ]; then
  pass_msg "prune keeps an UNANSWERED request however old (it is still a question)"
else
  fail_msg "prune deleted an unanswered request"
fi

# ---------------------------------------------------------------------------
scenario "usage: an unknown subcommand is rc 2 with usage on stderr"
# ---------------------------------------------------------------------------
run frobnicate
inc
if [ "$RC" -eq 2 ]; then
  pass_msg "an unknown subcommand exits 2"
else
  fail_msg "an unknown subcommand exited $RC (want 2)"
fi
inc
if grep -qiF 'usage' <<<"$ERR"; then
  pass_msg "an unknown subcommand prints usage on STDERR"
else
  fail_msg "an unknown subcommand printed no usage on stderr"
fi

# ---------------------------------------------------------------------------
scenario "queue dir resolution falls back to the project scratch dir"
# ---------------------------------------------------------------------------
FB="$WORKDIR/fallback"
mkdir -p "$FB/.claude/scratch/permission-queue"
printf '{"id":"fb-1","issue":"#7","tool_name":"Bash","tool_input":{"command":"ls"}}\n' \
  > "$FB/.claude/scratch/permission-queue/fb-1.json"
OUT="$(cd "$FB" && env -u PIPELINE_PERMISSION_BRIDGE_DIR PIPELINE_PROJECT_ROOT="$FB" \
        bash "$CLI" pending 2>&1)"; RC=$?
inc
if [ "$RC" -eq 0 ] && grep -qF 'fb-1' <<<"$OUT"; then
  pass_msg "with the knob unset the dir resolves to <project>/.claude/scratch/permission-queue"
else
  fail_msg "the fallback queue dir did not resolve (rc=$RC out=$(printf '%q' "$OUT"))"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
