#!/bin/bash
set -uo pipefail

# Tests for the --patch settings CLI mode of scripts/migrate-from-subtree.sh.
#
# Asserts:
#  - `--patch settings` runs ONLY the settings-detection + report/patch
#    emission block, then exits 0.
#  - `--patch settings` does NOT touch .claude-pipeline/ even if present.
#  - Plain invocation (no args) still runs the full migration (regression).

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
# Test 'patch-settings-mode': --patch settings runs ONLY the settings block.
# ---------------------------------------------------------------------------
echo "Test 'patch-settings-mode': --patch settings emits report, leaves .claude-pipeline/ untouched"

PROJ="$WORKDIR/proj-patch-settings"
mkdir -p "$PROJ/.claude-pipeline/hooks" "$PROJ/.claude"
# Two pipeline hook entries.
touch "$PROJ/.claude-pipeline/hooks/log-tool-use.sh"
touch "$PROJ/.claude-pipeline/hooks/restrict_paths.py"
cat > "$PROJ/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]}
    ],
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/restrict_paths.py"}]}
    ]
  }
}
EOF
# Sentinel content under .claude-pipeline/ that --patch settings must NOT delete.
echo "sentinel" > "$PROJ/.claude-pipeline/sentinel.txt"

STDOUT_LOG="$WORKDIR/patch.stdout"
STDERR_LOG="$WORKDIR/patch.stderr"
(cd "$PROJ" && bash "$MIGRATE_SH" --patch settings >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "patch-settings: exit 0"; else fail_msg "patch-settings: exit $EXIT"; fi

inc
if [ -f "$PROJ/.claude/settings.json.pipeline-migration-report.txt" ]; then
  pass_msg "patch-settings: report file created"
else
  fail_msg "patch-settings: report file missing"
fi

inc
if [ -d "$PROJ/.claude-pipeline" ] && [ -f "$PROJ/.claude-pipeline/sentinel.txt" ]; then
  pass_msg "patch-settings: .claude-pipeline/ untouched"
else
  fail_msg "patch-settings: .claude-pipeline/ was mutated by --patch settings"
fi

# ---------------------------------------------------------------------------
# Test 'no-arg full migration': plain invocation still runs full migration.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'no-arg full migration': plain invocation still removes .claude-pipeline/"

PROJ2="$WORKDIR/proj-full"
mkdir -p "$PROJ2/.claude-pipeline/hooks" "$PROJ2/.claude"
touch "$PROJ2/.claude-pipeline/hooks/log-tool-use.sh"
echo '{"hooks": []}' > "$PROJ2/.claude/settings.json"

(cd "$PROJ2" && bash "$MIGRATE_SH" >/dev/null 2>&1)
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "full: exit 0"; else fail_msg "full: exit $EXIT"; fi

inc
if [ ! -d "$PROJ2/.claude-pipeline" ]; then
  pass_msg "full: .claude-pipeline/ removed by full migration"
else
  fail_msg "full: .claude-pipeline/ still present after full migration"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
