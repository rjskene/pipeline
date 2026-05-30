#!/bin/bash
set -uo pipefail

# Regression guard for issue #676: prompt_one() in migrate-from-subtree.sh
# must NOT block forever when stdin is a non-tty open pipe that sends no
# input. Pre-fix, `read -r answer || answer=""` only handles EOF; an open
# non-tty pipe with no input blocks read indefinitely. The fix keeps the
# interactive-tty path (`[ -t 0 ]`) blocking as before, but on non-tty stdin
# uses a bounded `read -t` so a no-input open pipe falls through to the safe
# default N (do not remove) and returns promptly instead of hanging. (A piped
# answer that does arrive is still honored — see prompt-y/prompt-n in
# tests/test-migrate-from-subtree.sh.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/migrate-from-subtree.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

# --- Fake plugin root shipping a skill named "dummy" ---
PLUGIN_ROOT="$TMP/plugin-root"
mkdir -p "$PLUGIN_ROOT/skills/dummy"
touch "$PLUGIN_ROOT/skills/dummy/SKILL.md"

# --- Consumer with a basename-match skill (no .pipeline-managed marker)
#     so it lands in TO_PROMPT_SKILLS and reaches prompt_one() ---
CONSUMER="$TMP/consumer"
mkdir -p "$CONSUMER/.claude/skills/dummy" "$CONSUMER/scripts"
echo "user-authored skill content" > "$CONSUMER/.claude/skills/dummy/SKILL.md"

# Sibling helpers migrate-from-subtree.sh sources/calls.
cp "$SCRIPT_DIR/../scripts/_advisory-text.sh" "$CONSUMER/scripts/_advisory-text.sh"
cp "$SCRIPT_DIR/../scripts/scan-preservation-refs.sh" "$CONSUMER/scripts/scan-preservation-refs.sh"
cp "$SCRIPT_DIR/../scripts/migration-cleanup-claudemd.sh" "$CONSUMER/scripts/migration-cleanup-claudemd.sh" 2>/dev/null || true

cp "$HELPER" "$CONSUMER/scripts/migrate-from-subtree.sh"
chmod +x "$CONSUMER/scripts/migrate-from-subtree.sh"

echo "=== non-tty open-pipe stdin does not hang; defaults to N ==="
# A FIFO with a backgrounded writer that opens it but never sends data gives
# the script an OPEN non-tty pipe with no input and no EOF — exactly the
# condition that makes a bare `read` block forever. Unlike `sleep 30 | bash`,
# wrapping the consumer alone in `timeout 15` measures the migrate script's
# own runtime (the producer's lifetime no longer gates pipeline completion),
# so the timeout is a true hang detector: rc 124 == read blocked. With the
# fix, the bounded read times out fast, defaults to N, and exits well under 15s.
FIFO="$TMP/in.fifo"
mkfifo "$FIFO"
# Hold the write end open (no data) for the whole run so the read end never
# sees EOF. Backgrounded; reaped after the run.
sleep 30 > "$FIFO" &
WRITER=$!
START=$(date +%s)
(
  cd "$CONSUMER" \
    && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       timeout 15 bash scripts/migrate-from-subtree.sh < "$FIFO"
) > "$TMP/run.log" 2>&1
RC=$?
END=$(date +%s)
kill "$WRITER" 2>/dev/null
wait "$WRITER" 2>/dev/null
ELAPSED=$((END - START))

if [ "$RC" -eq 124 ]; then
  fail_msg "migrate-from-subtree.sh HUNG on non-tty stdin (timeout fired, rc=124, ${ELAPSED}s)"
  sed 's/^/    /' "$TMP/run.log"
else
  pass_msg "did not hang (rc=$RC, ${ELAPSED}s)"
fi

if [ "$ELAPSED" -ge 15 ]; then
  fail_msg "returned too slowly (${ELAPSED}s ≥ 15s) — possible partial block"
else
  pass_msg "returned promptly (${ELAPSED}s)"
fi

# Safe default = N => the basename-match skill must be PRESERVED.
if [ -f "$CONSUMER/.claude/skills/dummy/SKILL.md" ]; then
  pass_msg ".claude/skills/dummy preserved (defaulted to N)"
else
  fail_msg ".claude/skills/dummy was removed — non-tty stdin did not default to N"
fi

echo
echo "Result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
