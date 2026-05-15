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

# ---------------------------------------------------------------------------
# Task 2: detect legacy paths anywhere in file (outside any flagged section).
# ---------------------------------------------------------------------------
echo ""
echo "Test 'detect: legacy paths anywhere in file'"

assert_paths_finding() {
  local tag="$1" projdir="$2" sig="$3"
  local report="$projdir/.claude/migration-cleanup-report-claudemd.txt"
  inc
  if [ -f "$report" ]; then pass_msg "$tag: report exists"; else fail_msg "$tag: report missing"; fi
  inc
  if [ -f "$report" ] && grep -qF "$sig" "$report"; then
    pass_msg "$tag: report mentions signature ($sig)"
  else
    fail_msg "$tag: report missing signature ($sig)"
  fi
  inc
  if [ -f "$report" ] && grep -qF 'Legacy paths' "$report"; then
    pass_msg "$tag: report has Legacy paths subsection"
  else
    fail_msg "$tag: report missing Legacy paths subsection"
  fi
}

PROJ_PATHS_A="$WORKDIR/proj-paths-a"
mkdir -p "$PROJ_PATHS_A"
printf 'Run `bash .claude-pipeline/scripts/spawn-claude.sh` to begin.\n' > "$PROJ_PATHS_A/CLAUDE.md"
(cd "$PROJ_PATHS_A" && bash "$SCANNER_SH") >/dev/null 2>&1
assert_paths_finding "paths-A" "$PROJ_PATHS_A" ".claude-pipeline/"

PROJ_PATHS_B="$WORKDIR/proj-paths-b"
mkdir -p "$PROJ_PATHS_B"
printf 'Update with `git subtree pull --prefix .claude-pipeline ...` after upstream changes.\n' > "$PROJ_PATHS_B/CLAUDE.md"
(cd "$PROJ_PATHS_B" && bash "$SCANNER_SH") >/dev/null 2>&1
assert_paths_finding "paths-B" "$PROJ_PATHS_B" "subtree pull"

PROJ_PATHS_C="$WORKDIR/proj-paths-c"
mkdir -p "$PROJ_PATHS_C"
printf 'Run `bash install.sh` after cloning.\n' > "$PROJ_PATHS_C/CLAUDE.md"
(cd "$PROJ_PATHS_C" && bash "$SCANNER_SH") >/dev/null 2>&1
assert_paths_finding "paths-C" "$PROJ_PATHS_C" "install.sh"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
