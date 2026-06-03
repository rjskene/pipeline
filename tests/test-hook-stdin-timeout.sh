#!/bin/bash
set -uo pipefail

# Tests for issue #917 — every shipped hook must bound its stdin read with a
# fail-open timeout so a never-closing stdin can never wedge the session.
#
# Acceptance criterion: a guarded hook fed a never-closing stdin exits WITHIN
# its own self-limited timeout (exit 0), NOT 124 via an external kill. The test
# therefore must NOT wrap the hook in its own `timeout` (that would mask the
# bug); the hook self-limits and the test measures wall-clock + exit code.
#
# "Never-closing stdin" is produced by piping a long `sleep` into the hook:
# `sleep 30 | <hook>` keeps the read pipe open (no EOF) for 30s, far longer than
# any hook's 5s deadline, so an UNGUARDED hook blocks until the outer harness
# `timeout 300` kills it (test fails on elapsed/exit), while a GUARDED hook
# returns in ~timeout seconds with exit 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Run a command fed a never-closing stdin, measuring wall-clock and exit code.
# Sets globals: RUN_RC (exit code), RUN_ELAPSED (whole seconds).
#
# Does NOT wrap the command in its own `timeout` — the hook must self-limit.
# A never-closing stdin is provided via a FIFO held open by a backgrounded
# `sleep 30` (no EOF for 30s, far beyond any hook's 5s deadline). We wait ONLY
# on the hook PID — never on the producer — so RUN_ELAPSED reflects the hook's
# OWN exit, not the open-pipe lifetime. An UNGUARDED hook blocks the full 30s
# (the producer's lifetime), failing the elapsed/exit assertions; a GUARDED
# hook returns in ~timeout seconds with exit 0. The producer is reaped after.
run_with_blocking_stdin() {
  local start end fifo hookpid producerpid
  fifo="$(mktemp -u)"
  mkfifo "$fifo"
  start=$(date +%s)
  # Open the FIFO write end with a long sleep so the read end never sees EOF.
  ( sleep 30 > "$fifo" ) &
  producerpid=$!
  "$@" < "$fifo" >/dev/null 2>&1 &
  hookpid=$!
  wait "$hookpid"
  RUN_RC=$?
  end=$(date +%s)
  RUN_ELAPSED=$((end - start))
  kill "$producerpid" 2>/dev/null || true
  wait "$producerpid" 2>/dev/null || true
  rm -f "$fifo"
}

# ---------------------------------------------------------------------------
# Task 1 — shared helper read_event_stdin in subagent_log_utils.py.
# ---------------------------------------------------------------------------
echo "Task 1: read_event_stdin helper"

# (a) exists and is callable.
if python3 -c "
import sys
sys.path.insert(0, '$HOOKS_DIR')
import subagent_log_utils as m
assert hasattr(m, 'read_event_stdin'), 'read_event_stdin missing'
assert callable(m.read_event_stdin), 'read_event_stdin not callable'
" 2>/dev/null; then
  pass_msg "1a: read_event_stdin exists and is callable"
else
  fail_msg "1a: read_event_stdin missing/not callable"
fi

# (b) never-closing stdin → returns {} and exits 0 within timeout+buffer.
HELPER_PROG="
import sys
sys.path.insert(0, '$HOOKS_DIR')
from subagent_log_utils import read_event_stdin
result = read_event_stdin(timeout=1)
assert result == {}, 'expected {} on timeout, got %r' % (result,)
sys.exit(0)
"
run_with_blocking_stdin python3 -c "$HELPER_PROG"
if [ "$RUN_RC" = "0" ] && [ "$RUN_ELAPSED" -lt 3 ]; then
  pass_msg "1b: timeout→{} returns exit 0 in ${RUN_ELAPSED}s (<3s, not 124-via-kill)"
else
  fail_msg "1b: rc=$RUN_RC elapsed=${RUN_ELAPSED}s (want rc=0, <3s)"
fi

# (c) malformed JSON on a closed stdin → {}.
if [ "$(printf 'not json{' | python3 -c "
import sys
sys.path.insert(0, '$HOOKS_DIR')
from subagent_log_utils import read_event_stdin
print('OK' if read_event_stdin(timeout=2) == {} else 'BAD')
" 2>/dev/null)" = "OK" ]; then
  pass_msg "1c: malformed JSON → {}"
else
  fail_msg "1c: malformed JSON did not return {}"
fi

# (d) valid JSON → parsed dict.
if [ "$(printf '{"tool_name":"Agent","k":1}' | python3 -c "
import sys
sys.path.insert(0, '$HOOKS_DIR')
from subagent_log_utils import read_event_stdin
d = read_event_stdin(timeout=2)
print('OK' if d == {'tool_name':'Agent','k':1} else 'BAD:%r' % (d,))
" 2>/dev/null)" = "OK" ]; then
  pass_msg "1d: valid JSON → parsed dict"
else
  fail_msg "1d: valid JSON not parsed correctly"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
