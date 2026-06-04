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
# Env vars that short-circuit a hook's escape-hatch path BEFORE it reaches its
# stdin read. The orchestrator session exports ALLOW_ORCHESTRATOR_EDIT=true (the
# PATH C escape hatch) and may export ALLOW_DELETIONS; if either leaks into the
# test process, enforce-path-c-delegation.py / block_deletions.py exit 0 before
# the read and the timeout assertion passes for the WRONG reason. Strip them so
# each hook genuinely exercises read_event_stdin.
run_with_blocking_stdin() {
  local start end fifo hookpid producerpid
  fifo="$(mktemp -u)"
  mkfifo "$fifo"
  start=$(date +%s)
  # Open the FIFO write end with a long sleep so the read end never sees EOF.
  ( sleep 30 > "$fifo" ) &
  producerpid=$!
  env -u ALLOW_ORCHESTRATOR_EDIT -u ALLOW_DELETIONS "$@" < "$fifo" >/dev/null 2>&1 &
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

# ---------------------------------------------------------------------------
# Task 2 — every shipped Python hook bounds its stdin read (fed never-closing
# stdin → exits within timeout, exit 0, NOT 124-via-external-kill). Each hook is
# given the env it needs to actually REACH its stdin read; otherwise an early
# env-gate exit would falsely pass.
# ---------------------------------------------------------------------------
echo "Task 2: shipped Python hooks bound their stdin reads"

# name|env-prefix(space-separated VAR=val, or empty)
PY_HOOKS=(
  "log_subagent.py|"
  "capture_agent_cost.py|PIPELINE_LOGS_ENABLED=true"
  "enforce-ci-wait.py|CLAUDE_PIPELINE_SKILL=evaluate-issue-pr"
  "enforce-path-c-delegation.py|CLAUDE_PIPELINE_ISSUE_NUMBER=917"
  "block_deletions.py|"
  "restrict_paths.py|CLAUDE_PLUGIN_ROOT=$REPO_ROOT"
  "enforce-base-branch.py|"
  "enforce-comment-trust.py|"
  "check-ci-skip-markers.py|"
)

for row in "${PY_HOOKS[@]}"; do
  hook="${row%%|*}"
  envspec="${row#*|}"
  path="$HOOKS_DIR/$hook"

  if [ ! -f "$path" ]; then
    fail_msg "2[$hook]: hook file not found at $path"
    continue
  fi

  # (a) self-limited exit on never-closing stdin.
  if [ -n "$envspec" ]; then
    # shellcheck disable=SC2086
    run_with_blocking_stdin env $envspec python3 "$path"
  else
    run_with_blocking_stdin python3 "$path"
  fi
  if [ "$RUN_RC" = "0" ] && [ "$RUN_ELAPSED" -lt 8 ]; then
    pass_msg "2[$hook]: exit 0 in ${RUN_ELAPSED}s on never-closing stdin (not 124-via-kill)"
  else
    fail_msg "2[$hook]: rc=$RUN_RC elapsed=${RUN_ELAPSED}s (want rc=0, <8s, not external kill)"
  fi

  # (b) grep guard — no bare json.load(sys.stdin) / unguarded sys.stdin.read().
  if grep -Eq 'json\.load\(sys\.stdin\)|sys\.stdin\.read\(\)' "$path"; then
    fail_msg "2[$hook]: still contains an unguarded stdin read"
  else
    pass_msg "2[$hook]: no bare json.load(sys.stdin)/sys.stdin.read()"
  fi
done

# ---------------------------------------------------------------------------
# Task 3 — bash hook log-tool-use.sh bounds its `cat` stdin read with timeout.
# ---------------------------------------------------------------------------
echo "Task 3: log-tool-use.sh bounds its stdin read"

BASH_HOOK="$HOOKS_DIR/log-tool-use.sh"
if [ ! -f "$BASH_HOOK" ]; then
  fail_msg "3[log-tool-use.sh]: hook file not found at $BASH_HOOK"
else
  # (a) self-limited exit on never-closing stdin (run in a writable scratch dir
  # so the hook's mkdir/log write does not touch unexpected paths).
  TMP3="$(mktemp -d)"
  run_with_blocking_stdin env "CLAUDE_PROJECT_DIR=$TMP3" bash "$BASH_HOOK"
  rm -rf "$TMP3"
  if [ "$RUN_RC" = "0" ] && [ "$RUN_ELAPSED" -lt 8 ]; then
    pass_msg "3[log-tool-use.sh]: exit 0 in ${RUN_ELAPSED}s on never-closing stdin (not 124-via-kill)"
  else
    fail_msg "3[log-tool-use.sh]: rc=$RUN_RC elapsed=${RUN_ELAPSED}s (want rc=0, <8s, not external kill)"
  fi

  # (b) grep guard — the stdin `cat` capture is wrapped with `timeout`.
  if grep -Eq 'INPUT=\$\(\s*timeout\b' "$BASH_HOOK"; then
    pass_msg "3[log-tool-use.sh]: stdin cat wrapped with timeout"
  else
    fail_msg "3[log-tool-use.sh]: bare INPUT=\$(cat) — not timeout-wrapped"
  fi
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
