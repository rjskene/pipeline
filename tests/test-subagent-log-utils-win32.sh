#!/bin/bash
set -uo pipefail

# Tests for issue #968 — hooks/subagent_log_utils.py is POSIX-only (top-level
# `import fcntl` + `signal.SIGALRM`/`signal.alarm` in read_event_stdin), so on
# Windows the Stop/subagent hooks traceback at import / call time.
#
# We cannot run a Windows host in CI, so we SIMULATE win32 in-process on the
# POSIX host: the failure is at Python import / attribute resolution, which the
# simulation reproduces exactly.
#   - `sys.modules['fcntl'] = None` BEFORE import → `import fcntl` raises
#     ImportError (a None entry mimics an absent module).
#   - `del signal.SIGALRM` → mimics win32's signal module lacking SIGALRM.
#
# Asserts:
#   Task 1 — import-clean with fcntl hidden + append_locked fails open (writes
#            without a lock).
#   Task 2 — read_event_stdin does not raise without SIGALRM, still parses valid
#            JSON / returns {} on malformed.
#   Task 3 — every hook importing subagent_log_utils imports cleanly with both
#            fcntl hidden and SIGALRM absent (standing regression guard).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Task 1 — import-clean with fcntl hidden + append_locked fail-open.
# ---------------------------------------------------------------------------
echo "Task 1: fcntl-hidden import-cleanliness + append_locked fail-open"

TMP="$(mktemp -d)"
OUT=$(python3 -c "
import sys
sys.modules['fcntl'] = None          # force ImportError on 'import fcntl'
sys.path.insert(0, '$HOOKS_DIR')
import subagent_log_utils as m        # must NOT raise
from pathlib import Path
p = Path('$TMP') / 'sub' / 'c.log'
m.append_locked(p, 'line-one')        # must NOT raise; must write (fail-open)
m.append_locked(p, 'line-two')
print(p.read_text().strip())
" 2>&1)
rc=$?
rm -rf "$TMP"
if [ "$rc" = "0" ] && [ "$OUT" = $'line-one\nline-two' ]; then
  pass "1: import-clean with fcntl=None; append_locked wrote both lines fail-open"
else
  fail "1: rc=$rc out=$(printf '%q' "$OUT")"
fi

# ---------------------------------------------------------------------------
# Task 2 — read_event_stdin guards SIGALRM/alarm (no AttributeError on win32).
# ---------------------------------------------------------------------------
echo "Task 2: read_event_stdin SIGALRM-absent guard"

# (a) valid JSON parsed without raising AttributeError when SIGALRM absent.
OUT=$(printf '{"tool_name":"Agent","k":1}' | python3 -c "
import sys, signal
if hasattr(signal, 'SIGALRM'): del signal.SIGALRM   # mimic win32: no SIGALRM
sys.path.insert(0, '$HOOKS_DIR')
from subagent_log_utils import read_event_stdin
d = read_event_stdin(timeout=2)                      # must NOT raise AttributeError
print('OK' if d == {'tool_name':'Agent','k':1} else 'BAD:%r' % (d,))
" 2>&1)
if [ "$OUT" = "OK" ]; then
  pass "2a: valid JSON parsed with SIGALRM absent"
else
  fail "2a: out=$(printf '%q' "$OUT")"
fi

# (b) malformed JSON → {} under SIGALRM-absent condition.
OUT=$(printf 'not json{' | python3 -c "
import sys, signal
if hasattr(signal, 'SIGALRM'): del signal.SIGALRM
sys.path.insert(0, '$HOOKS_DIR')
from subagent_log_utils import read_event_stdin
print('OK' if read_event_stdin(timeout=2) == {} else 'BAD')
" 2>&1)
if [ "$OUT" = "OK" ]; then
  pass "2b: malformed JSON → {} with SIGALRM absent"
else
  fail "2b: out=$(printf '%q' "$OUT")"
fi

# ---------------------------------------------------------------------------
# Task 3 — every hook importing subagent_log_utils stays win32 import-clean.
# Loads each hook file via importlib (filenames use hyphens so they cannot be
# `import`ed by module name); exec_module runs the top-level imports we guard.
# ---------------------------------------------------------------------------
echo "Task 3: all subagent_log_utils importers stay win32 import-clean"

HOOKS=(enforce-comment-trust enforce-base-branch restrict_paths block_deletions \
       log_subagent enforce-ci-wait check-ci-skip-markers enforce-path-c-delegation \
       capture_agent_cost)
for h in "${HOOKS[@]}"; do
  if python3 -c "
import sys, signal
sys.modules['fcntl'] = None
if hasattr(signal,'SIGALRM'): del signal.SIGALRM
sys.path.insert(0, '$HOOKS_DIR')
import importlib.util as u
spec = u.spec_from_file_location('h_$h', '$HOOKS_DIR/$h.py')
mod = u.module_from_spec(spec)
spec.loader.exec_module(mod)   # executes top-level imports; must NOT raise
" 2>/dev/null; then
    pass "3: import-clean: $h"
  else
    fail "3: import FAILED: $h"
  fi
done

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
