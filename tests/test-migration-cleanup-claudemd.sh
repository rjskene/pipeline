#!/bin/bash
set -uo pipefail

# Tests for scripts/migration-cleanup-claudemd.sh — the advisory CLAUDE.md
# scanner that flags pipeline-legacy content and emits a unified-diff patch
# without ever mutating source files.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCANNER_SH="$SCRIPT_DIR/../scripts/migration-cleanup-claudemd.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Task 1: detect pure pipeline section headers (gated by corroborating sig).
# ---------------------------------------------------------------------------
echo "Test 'detect: pure pipeline section headers'"

PROJ_HDR="$WORKDIR/proj-hdr"
mkdir -p "$PROJ_HDR"
cat > "$PROJ_HDR/CLAUDE.md" <<'EOF'
## Pipeline

Run `bash .claude-pipeline/scripts/spawn-claude.sh` to launch.
EOF

(cd "$PROJ_HDR" && bash "$SCANNER_SH") >/dev/null 2>&1
EXIT=$?

REPORT="$PROJ_HDR/.claude/migration-cleanup-report-claudemd.txt"

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "hdr: exit 0"; else fail_msg "hdr: exit $EXIT"; fi

inc
if [ -f "$REPORT" ]; then pass_msg "hdr: report file created"; else fail_msg "hdr: report file missing"; fi

inc
if [ -f "$REPORT" ] && grep -qF 'CLAUDE.md:1:' "$REPORT"; then
  pass_msg "hdr: report mentions line 1"
else
  fail_msg "hdr: report missing CLAUDE.md:1:"
  [ -f "$REPORT" ] && sed 's/^/    /' "$REPORT"
fi

inc
if [ -f "$REPORT" ] && grep -qF '## Pipeline' "$REPORT"; then
  pass_msg "hdr: report mentions ## Pipeline"
else
  fail_msg "hdr: report missing ## Pipeline"
fi

inc
if [ -f "$REPORT" ] && grep -qF '.claude-pipeline/' "$REPORT"; then
  pass_msg "hdr: report mentions corroborating .claude-pipeline/"
else
  fail_msg "hdr: report missing corroborating signature"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
