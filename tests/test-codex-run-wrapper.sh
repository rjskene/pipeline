#!/bin/bash
set -euo pipefail

# Tests for hooks/_run.sh — the path-agnostic hook launcher (issue #981) that
# .codex/config.toml uses so the committed config references hooks by bare
# script name (hooks/_run.sh <script>) instead of a host-specific absolute path.
#
# Contract proven here:
#   (i)   execs the named hook AND forwards stdin — pipe a payload the chosen
#         script blocks on and expect that script's exit code + BLOCKED stderr.
#   (ii)  self-resolves CLAUDE_PLUGIN_ROOT when unset — run with the var unset
#         but inside the repo so the resolver's git-origin branch sets it, and
#         assert the wrapper still runs the script (the block still fires).
#   (iii) errors clearly when no script name is given (exit non-zero).

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$REPO_ROOT/hooks/_run.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$RUN" ]; then
  echo "ERROR: launcher not found at $RUN" >&2
  exit 1
fi

# A Bash payload that block_deletions.py blocks on (exit 1 + BLOCKED stderr).
# block_deletions is a good probe: zero external deps, deterministic.
DESTRUCTIVE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'

# ---------------------------------------------------------------------------
# (i) execs the named hook and forwards stdin. CLAUDE_PLUGIN_ROOT is exported
#     (the happy path), so the wrapper execs $CLAUDE_PLUGIN_ROOT/hooks/<script>.
#     The block contract must propagate through `exec` unchanged.
# ---------------------------------------------------------------------------
echo "(i) _run.sh execs the hook and forwards stdin (block propagates)"
inc
TMP_ERR="$(mktemp)"
set +e
printf '%s' "$DESTRUCTIVE_PAYLOAD" | env -i PATH="$PATH" \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  bash "$RUN" block_deletions.py >/dev/null 2>"$TMP_ERR"
RC=$?
set -e
ERR="$(cat "$TMP_ERR")"; rm -f "$TMP_ERR"
if [ "$RC" = "1" ] && printf '%s' "$ERR" | grep -q "BLOCKED: destructive deletion"; then
  pass_msg "exit 1 + BLOCKED stderr forwarded through exec"
else
  fail_msg "exec+stdin" "expected exit 1 + BLOCKED stderr; got rc=$RC stderr='$ERR'"
fi

# Sub-assertion: stdin really IS forwarded — a payload that does NOT block must
# pass through to exit 0 (proves the hook saw the stdin, not that _run.sh always
# blocks). A benign command exits 0.
echo "(i-b) _run.sh forwards a non-blocking payload to a clean exit 0"
inc
BENIGN_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
set +e
printf '%s' "$BENIGN_PAYLOAD" | env -i PATH="$PATH" \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  bash "$RUN" block_deletions.py >/dev/null 2>/dev/null
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass_msg "non-blocking payload -> exit 0 (stdin forwarded, not swallowed)"
else
  fail_msg "stdin-forward" "expected exit 0 for benign payload, got rc=$RC"
fi

# ---------------------------------------------------------------------------
# (ii) self-resolves CLAUDE_PLUGIN_ROOT when unset. Run with the var UNSET but
#      with cwd inside the repo and PIPELINE_USE_LOCAL_PLUGIN=true so the
#      resolver's git-origin branch (scripts/_resolve-plugin-root.sh) matches
#      the rjskene/pipeline origin and exports the working-tree root. The
#      wrapper must still exec the hook — proven by the block still firing.
#      (env carries HOME + a real PATH so git is available to the resolver.)
# ---------------------------------------------------------------------------
echo "(ii) _run.sh self-resolves CLAUDE_PLUGIN_ROOT when unset (git-origin branch)"
inc
TMP_ERR="$(mktemp)"
set +e
( cd "$REPO_ROOT" && printf '%s' "$DESTRUCTIVE_PAYLOAD" | env -i \
    HOME="$HOME" PATH="$PATH" PIPELINE_USE_LOCAL_PLUGIN=true \
    bash "$RUN" block_deletions.py >/dev/null 2>"$TMP_ERR" )
RC=$?
set -e
ERR="$(cat "$TMP_ERR")"; rm -f "$TMP_ERR"
if [ "$RC" = "1" ] && printf '%s' "$ERR" | grep -q "BLOCKED: destructive deletion"; then
  pass_msg "ran hook with CLAUDE_PLUGIN_ROOT unset (resolver set it; block fired)"
else
  fail_msg "self-resolve" "expected exit 1 + BLOCKED stderr with unset root; got rc=$RC stderr='$ERR'"
fi

# ---------------------------------------------------------------------------
# (iii) errors clearly when no script name is given. _run.sh uses
#       ${1:?...} under `set -u`, so a missing arg aborts non-zero with a
#       diagnostic that names the launcher.
# ---------------------------------------------------------------------------
echo "(iii) _run.sh errors (non-zero) when no script name is given"
inc
TMP_ERR="$(mktemp)"
set +e
env -i PATH="$PATH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  bash "$RUN" </dev/null >/dev/null 2>"$TMP_ERR"
RC=$?
set -e
ERR="$(cat "$TMP_ERR")"; rm -f "$TMP_ERR"
if [ "$RC" != "0" ] && printf '%s' "$ERR" | grep -qi "_run.sh"; then
  pass_msg "exit $RC + diagnostic naming _run.sh (missing script name)"
else
  fail_msg "missing-arg" "expected non-zero exit + _run.sh diagnostic; got rc=$RC stderr='$ERR'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
