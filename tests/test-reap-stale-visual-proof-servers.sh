#!/bin/bash
set -euo pipefail

# Tests for scripts/reap-stale-visual-proof-servers.sh — the helper that
# enumerates `python3 -m http.server` processes, identifies their enclosing
# worktree via the `--directory` arg + `.git` walk, and SIGTERM/SIGKILLs any
# whose worktree is no longer registered with `git worktree list`.
#
# Strategy: start a real http.server bound to a temp dir, then `rm -rf` that
# dir so the enclosing worktree lookup fails (no `.git` ancestor) — which
# the reaper must treat as "stale" and kill. Assert the PID is gone within
# 5 s.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/reap-stale-visual-proof-servers.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d)
cleanup() {
  # Best-effort kill of any lingering server we started.
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -9 "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# ---- Sandbox harness ----
# Temp git repo so the reaper's `git worktree list` never reads the real repo.
REAP_REPO="$TMP/repo"
mkdir -p "$REAP_REPO"
git -C "$REAP_REPO" init -q
git -C "$REAP_REPO" commit --allow-empty -qm init

# Stub dir: the stub `pgrep` placed here shadows the real one for the reaper.
STUB="$TMP/stub"
mkdir -p "$STUB"

# ---- Case A: helper exists and is executable-ish ----
echo "Case A: helper file is present"
inc
if [ -f "$HELPER" ]; then
  pass_msg "helper present at $HELPER"
else
  fail_msg "helper missing at $HELPER"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

# ---- Case B: no servers running → prints "(no stale servers)" and exits 0 ----
echo "Case B: no matching processes → quiet success"
inc
# Stub pgrep emits nothing → reaper sees no servers.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/pgrep"; chmod +x "$STUB/pgrep"
if PIPELINE_REPO_ROOT="$REAP_REPO" PATH="$STUB:$PATH" bash "$HELPER" >"$TMP/b.out" 2>"$TMP/b.err"; then
  pass_msg "helper exits 0 with no work to do (or only live servers)"
else
  rc=$?
  fail_msg "helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$TMP/b.err"
fi

# ---- Case C: stale server (its --directory was rm -rf'd) is reaped ----
echo "Case C: stale server gets SIGTERM/SIGKILL within 5 s"
inc

STALE_DIR="$TMP/stale-dir"
mkdir -p "$STALE_DIR"

# Start a real python http.server bound to that dir.
python3 -m http.server 0 --directory "$STALE_DIR" --bind 127.0.0.1 \
  >"$TMP/server.out" 2>"$TMP/server.err" &
SERVER_PID=$!

# Give it a moment to actually start so pgrep finds it.
sleep 1

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  fail_msg "test setup: server PID $SERVER_PID died before reaper ran"
  echo "    server.err:"; sed 's/^/      /' "$TMP/server.err"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

# Yank the directory out from under the server so its enclosing `.git`
# walk fails and the worktree-list cross-check classifies it as stale.
rm -rf "$STALE_DIR"

# Stub pgrep emits exactly this test's server line so the reaper sees it
# (and only it) — never enumerating real host processes.
printf '#!/usr/bin/env bash\necho "%s python3 -m http.server 0 --directory %s --bind 127.0.0.1"\n' \
  "$SERVER_PID" "$STALE_DIR" > "$STUB/pgrep"; chmod +x "$STUB/pgrep"

# Run the reaper with sandboxed pgrep + isolated git repo.
PIPELINE_REPO_ROOT="$REAP_REPO" PATH="$STUB:$PATH" bash "$HELPER" >"$TMP/c.out" 2>"$TMP/c.err" || {
  rc=$?
  fail_msg "helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$TMP/c.err"
}

# Wait up to 5 s for the PID to disappear.
gone=0
for _ in 1 2 3 4 5; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    gone=1
    break
  fi
  sleep 1
done

if [ "$gone" = "1" ]; then
  pass_msg "stale server PID $SERVER_PID was reaped"
else
  fail_msg "stale server PID $SERVER_PID still alive after 5 s"
  echo "    stdout:"; sed 's/^/      /' "$TMP/c.out"
  echo "    stderr:"; sed 's/^/      /' "$TMP/c.err"
  kill -9 "$SERVER_PID" 2>/dev/null || true
fi

# ---- Case D: reaper emits the documented EVENT line on kill ----
echo "Case D: EVENT line emitted on reap"
inc
if grep -qE '^EVENT: reaped pid=[0-9]+ dir=' "$TMP/c.out"; then
  pass_msg "EVENT line present in stdout"
else
  fail_msg "EVENT line missing"
  echo "    stdout:"; sed 's/^/      /' "$TMP/c.out"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
