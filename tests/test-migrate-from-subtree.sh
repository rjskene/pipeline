#!/bin/bash
set -euo pipefail

# Tests for scripts/migrate-from-subtree.sh — the consumer-facing migration
# script that removes pipeline-managed files installed via the legacy subtree
# + install.sh path.
#
# Each test builds an isolated $PROJ fixture under a per-test mktemp dir,
# invokes the migration script from that dir, and asserts on filesystem
# state, stdout, and stderr.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE_SH="$SCRIPT_DIR/../scripts/migrate-from-subtree.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$MIGRATE_SH" ]; then
  echo "ERROR: migrate-from-subtree.sh not found at $MIGRATE_SH" >&2
  exit 1
fi
chmod +x "$MIGRATE_SH"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Test "absent": no .claude-pipeline/, no markers, no .claude/agents — script
# is a no-op. Snapshot fs state, run, snapshot again, require identical.
# ---------------------------------------------------------------------------
echo "Test 'absent': no-op when nothing pipeline-managed exists"

PROJ_ABSENT="$WORKDIR/proj-absent"
mkdir -p "$PROJ_ABSENT"
# Some user content so the dir isn't trivially empty
echo "hello" > "$PROJ_ABSENT/README.md"
mkdir -p "$PROJ_ABSENT/.claude"
echo '{"hooks": []}' > "$PROJ_ABSENT/.claude/settings.json"

BEFORE=$(cd "$PROJ_ABSENT" && find . -type f -o -type d | sort)
STDERR_LOG="$WORKDIR/absent.stderr"
STDOUT_LOG="$WORKDIR/absent.stdout"
(cd "$PROJ_ABSENT" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?
AFTER=$(cd "$PROJ_ABSENT" && find . -type f -o -type d | sort)

inc
if [ "$EXIT" -eq 0 ]; then
  pass_msg "absent: exit 0"
else
  fail_msg "absent: exit $EXIT"
fi

inc
if [ "$BEFORE" = "$AFTER" ]; then
  pass_msg "absent: filesystem unchanged"
else
  fail_msg "absent: filesystem changed"
  diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/    /'
fi

inc
if grep -qi 'nothing to migrate' "$STDERR_LOG"; then
  pass_msg "absent: stderr mentions 'nothing to migrate'"
else
  fail_msg "absent: stderr missing 'nothing to migrate'"
  echo "    stderr:"
  sed 's/^/      /' "$STDERR_LOG"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
