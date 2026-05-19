#!/usr/bin/env bash
# Smoke tests for scripts/review-logs.sh project-root resolution.
# Mirrors the test shape of tests/test_create_checkpoint_tag.sh (#277 / PR #282).
set -uo pipefail

export PIPELINE_LOGS_ENABLED=true

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/review-logs.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; echo "    -- output --"; echo "$2" | sed 's/^/    /'; }

_seed_consumer() {
  # Args: $1=dir
  local dir="$1"
  mkdir -p "$dir/.claude/logs"
  touch "$dir/pipeline.config"
  mkdir -p "$dir/.git"
  # Seed one issue log so the summary path emits a row.
  printf 'ERROR: smoke\n' > "$dir/.claude/logs/issue-999-20260101T000000.log"
}

# ---- Test 1: walk-up from $0 resolves seeded consumer dir ----
echo "Test 1: walk-up resolves consumer root"
TMP1="$(mktemp -d)"
_seed_consumer "$TMP1"
# Stage the script inside a fake plugin-style tree under the consumer dir
# so dirname-walking actually finds the seeded pipeline.config + .git.
mkdir -p "$TMP1/fake-plugin/scripts"
cp "$SCRIPT" "$TMP1/fake-plugin/scripts/review-logs.sh"
chmod +x "$TMP1/fake-plugin/scripts/review-logs.sh"
OUT1=$(env -u PIPELINE_PROJECT_ROOT bash "$TMP1/fake-plugin/scripts/review-logs.sh" 2>&1 || true)
if echo "$OUT1" | grep -q "issue-999-20260101T000000.log"; then
  _pass "Test 1: summary lists seeded log"
else
  _fail "Test 1: summary missing seeded log" "$OUT1"
fi
rm -rf "$TMP1"

# ---- Test 2: PIPELINE_PROJECT_ROOT override wins ----
echo "Test 2: PIPELINE_PROJECT_ROOT override"
TMP2="$(mktemp -d)"
_seed_consumer "$TMP2"
OUT2=$(PIPELINE_PROJECT_ROOT="$TMP2" bash "$SCRIPT" 2>&1 || true)
if echo "$OUT2" | grep -q "issue-999-20260101T000000.log"; then
  _pass "Test 2: override resolves seeded log"
else
  _fail "Test 2: override missed seeded log" "$OUT2"
fi
rm -rf "$TMP2"

# ---- Test 3: stray pipeline.config without .git/ is rejected ----
echo "Test 3: stray pipeline.config without .git is rejected"
TMP3="$(mktemp -d)"
# Outer dir has pipeline.config but NO .git (the plugin-tree shape).
touch "$TMP3/pipeline.config"
# Inner dir IS a real consumer (has both pipeline.config AND .git/).
mkdir -p "$TMP3/inner/.git"
mkdir -p "$TMP3/inner/.claude/logs"
touch "$TMP3/inner/pipeline.config"
printf 'ERROR: inner\n' > "$TMP3/inner/.claude/logs/issue-777-20260101T000000.log"
mkdir -p "$TMP3/inner/fake-plugin/scripts"
cp "$SCRIPT" "$TMP3/inner/fake-plugin/scripts/review-logs.sh"
chmod +x "$TMP3/inner/fake-plugin/scripts/review-logs.sh"
OUT3=$(env -u PIPELINE_PROJECT_ROOT bash "$TMP3/inner/fake-plugin/scripts/review-logs.sh" 2>&1 || true)
# Walk-up must stop at "inner" (which has both), not at the outer stray.
if echo "$OUT3" | grep -q "issue-777-20260101T000000.log"; then
  _pass "Test 3: walk-up stops at directory with both pipeline.config AND .git"
else
  _fail "Test 3: stray pipeline.config was not rejected" "$OUT3"
fi
rm -rf "$TMP3"

# ---- Test 4: --subagents path uses resolved project root ----
echo "Test 4: --subagents path resolves project root"
TMP4="$(mktemp -d)"
_seed_consumer "$TMP4"
# Seed a subagents.log with one tab-separated row.
printf '2026-01-01T00:00:00Z\tsession-abc\tdo-stuff\t100\t10\t250\tfile.json\n' \
  > "$TMP4/.claude/logs/subagents.log"
OUT4=$(PIPELINE_PROJECT_ROOT="$TMP4" bash "$SCRIPT" --subagents 2>&1 || true)
if echo "$OUT4" | grep -q "do-stuff"; then
  _pass "Test 4: --subagents reads from resolved project root"
else
  _fail "Test 4: --subagents did not find seeded subagents.log" "$OUT4"
fi
rm -rf "$TMP4"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
