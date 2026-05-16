#!/bin/bash
set -uo pipefail

# Tests that migrate-from-subtree.sh's SETTINGS_REPORT emits per-basename
# annotation lines sourced from scripts/_advisory-text.sh — string equality
# against advisory_for_hook(<basename>) for each of the three common
# pipeline-owned hook entries: restrict_paths.py, log-tool-use.sh,
# log_subagent.py.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE_SH="$SCRIPT_DIR/../scripts/migrate-from-subtree.sh"
ADVISORY_SH="$SCRIPT_DIR/../scripts/_advisory-text.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$MIGRATE_SH" ] || [ ! -f "$ADVISORY_SH" ]; then
  echo "ERROR: required scripts missing" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ADVISORY_SH"

EXPECTED_RESTRICT=$(advisory_for_hook restrict_paths.py)
EXPECTED_TOOLUSE=$(advisory_for_hook log-tool-use.sh)
EXPECTED_SUBAGENT=$(advisory_for_hook log_subagent.py)

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj-advisory"
mkdir -p "$PROJ/.claude"
cat > "$PROJ/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/restrict_paths.py"}]}
    ],
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]},
      {"hooks": [{"type": "command", "command": ".claude/hooks/log_subagent.py"}]}
    ]
  }
}
EOF

(cd "$PROJ" && bash "$MIGRATE_SH" >/dev/null 2>&1) || true

REPORT="$PROJ/.claude/settings.json.pipeline-migration-report.txt"

inc
if [ -f "$REPORT" ]; then
  pass_msg "advisory-shared: report exists"
else
  fail_msg "advisory-shared: report missing"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

inc
if grep -qF "$EXPECTED_RESTRICT" "$REPORT"; then
  pass_msg "advisory-shared: restrict_paths.py annotation present (string equality)"
else
  fail_msg "advisory-shared: restrict_paths.py annotation missing"
  echo "    expected: $EXPECTED_RESTRICT"
fi

inc
if grep -qF "$EXPECTED_TOOLUSE" "$REPORT"; then
  pass_msg "advisory-shared: log-tool-use.sh annotation present (string equality)"
else
  fail_msg "advisory-shared: log-tool-use.sh annotation missing"
  echo "    expected: $EXPECTED_TOOLUSE"
fi

inc
if grep -qF "$EXPECTED_SUBAGENT" "$REPORT"; then
  pass_msg "advisory-shared: log_subagent.py annotation present (string equality)"
else
  fail_msg "advisory-shared: log_subagent.py annotation missing"
  echo "    expected: $EXPECTED_SUBAGENT"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
