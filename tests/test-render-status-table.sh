#!/bin/bash
set -uo pipefail

# Tests for scripts/render-status-table.sh — the deterministic, hermetic
# renderer that consumes (issues.json, trackers.json, release-prs.txt) and
# writes the canonical pipeline status table to stdout.
#
# The renderer makes ZERO live `gh` calls. All inputs are passed as files,
# which is what makes this testable in shell.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/render-status-table.sh"
FIXTURES="$SCRIPT_DIR/fixtures/render-status-table"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); echo "    $2"; }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# ----------------------------------------------------------------------
# Task 1: skeleton + arg parsing
# ----------------------------------------------------------------------

# Scenario 1.1: no arguments → exit 2 + usage to stderr
inc
out=$(bash "$HELPER" 2>"$TMP/err" || true)
rc=$?
err=$(cat "$TMP/err")
if bash "$HELPER" >/dev/null 2>"$TMP/err"; rc=$?; [ "$rc" -eq 2 ] && grep -q -i 'usage' "$TMP/err"; then
  pass_msg "no args → exit 2 + usage on stderr"
else
  fail_msg "no args → exit 2 + usage on stderr" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# Scenario 1.2: --issues pointing at a nonexistent file → exit 2 + error
inc
bash "$HELPER" --issues "$TMP/does-not-exist.json" >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "does-not-exist.json" "$TMP/err"; then
  pass_msg "missing --issues file → exit 2 + error mentions file"
else
  fail_msg "missing --issues file → exit 2 + error mentions file" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# Scenario 1.3: --issues with a valid empty file (just '[]') exits 0
inc
echo '[]' > "$TMP/empty-issues.json"
bash "$HELPER" --issues "$TMP/empty-issues.json" --today 2026-05-21 >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "empty issues array → exit 0"
else
  fail_msg "empty issues array → exit 0" "rc=$rc, stderr=$(cat "$TMP/err"), stdout=$(cat "$TMP/out")"
fi

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "TOTAL: $TESTS  PASS: $PASS  FAIL: $FAIL"
echo "=========================================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
