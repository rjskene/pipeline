#!/bin/bash
set -uo pipefail
#
# Tests for the PIPELINE_LOGS_ENABLED gate on analyze-issues.sh shortlist
# output path (issue #318).
#
# Contract: when logging is disabled, the shortlist JSON is written under
# $TMPDIR (mktemp) instead of .claude/logs/. The stdout absolute-path
# contract is unchanged.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/analyze-issues.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

cat > "$TMP/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/test-repo"
CFG

FIX="$TMP/fix"; mkdir -p "$FIX"
echo "[]" > "$FIX/issues.json"

# --- Scenario A: PIPELINE_LOGS_ENABLED=false routes to mktemp ---
echo ""
echo "-- Scenario A: logging disabled routes to mktemp --"
rm -rf "$TMP/.claude"
outA=$( cd "$TMP" && PIPELINE_LOGS_ENABLED=false bash "$HELPER" --fixture "$FIX" 2>&1 )
rcA=$?
pathA=$(echo "$outA" | tail -n 1)
echo "    stdout path: $pathA"

if [ "$rcA" -eq 0 ]; then
  pass_msg "A: exit 0"
else
  fail_msg "A: exit 0 (rc=$rcA)"
fi

if [ -f "$pathA" ]; then
  pass_msg "A: stdout points to an existing file"
else
  fail_msg "A: stdout points to an existing file ($pathA)"
fi

case "$pathA" in
  /*) pass_msg "A: stdout path is absolute" ;;
  *)  fail_msg "A: stdout path is absolute (got '$pathA')" ;;
esac

if [ -d "$TMP/.claude/logs" ] && [ -n "$(ls -A "$TMP/.claude/logs" 2>/dev/null)" ]; then
  fail_msg "A: no file written under .claude/logs/"
  ls -la "$TMP/.claude/logs" | sed 's/^/      /'
else
  pass_msg "A: no file written under .claude/logs/"
fi

# Path should live under $TMPDIR or /tmp.
case "$pathA" in
  "${TMPDIR:-/tmp}"/*|/tmp/*)
    pass_msg "A: path is under TMPDIR or /tmp"
    ;;
  *)
    fail_msg "A: path under TMPDIR or /tmp (got '$pathA')"
    ;;
esac

# Sanity: it is valid JSON with expected keys.
if jq -e 'has("duplicate_pairs") and has("tracker_fits") and has("missing_label_candidates")' "$pathA" >/dev/null 2>&1; then
  pass_msg "A: file is valid JSON with expected keys"
else
  fail_msg "A: file is valid JSON with expected keys"
fi

# --- Scenario B: PIPELINE_LOGS_ENABLED=true preserves legacy path ---
echo ""
echo "-- Scenario B: logging enabled preserves .claude/logs path --"
rm -rf "$TMP/.claude"
outB=$( cd "$TMP" && PIPELINE_LOGS_ENABLED=true bash "$HELPER" --fixture "$FIX" 2>&1 )
rcB=$?
pathB=$(echo "$outB" | tail -n 1)
echo "    stdout path: $pathB"

if [ "$rcB" -eq 0 ]; then
  pass_msg "B: exit 0"
else
  fail_msg "B: exit 0 (rc=$rcB)"
fi

if [ -f "$pathB" ]; then
  pass_msg "B: stdout points to an existing file"
else
  fail_msg "B: stdout points to an existing file ($pathB)"
fi

case "$pathB" in
  */.claude/logs/analyze-shortlist-*.json)
    pass_msg "B: path matches .claude/logs/analyze-shortlist-*.json"
    ;;
  *)
    fail_msg "B: path matches .claude/logs/analyze-shortlist-*.json (got '$pathB')"
    ;;
esac

shopt -s nullglob
matches=( "$TMP/.claude/logs/analyze-shortlist-"*.json )
if [ "${#matches[@]}" -ge 1 ]; then
  pass_msg "B: at least one .claude/logs/analyze-shortlist-*.json file present"
else
  fail_msg "B: .claude/logs/analyze-shortlist-*.json present"
fi
shopt -u nullglob

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
