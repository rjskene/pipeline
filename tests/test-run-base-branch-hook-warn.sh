#!/bin/bash
# tests/test-run-base-branch-hook-warn.sh
#
# Covers the housekeeping advisory in /pipeline:run that warns when the
# enforce-base-branch.py hook is NOT wired in either the plugin manifest
# (.claude-plugin/plugin.json) OR the consumer settings (.claude/settings.json).
#
# Driven via the helper scripts/check-base-branch-hook-wiring.sh which the
# skill invokes from its housekeeping section. The helper is silent when at
# least one side wires the hook and emits a single WARN line when neither side
# does. It always exits 0 (non-fatal advisory).
#
# Three fixtures:
#   (a) plugin-registered, consumer absent       -> no output
#   (b) consumer-registered, plugin absent       -> no output
#   (c) neither wires the hook                   -> WARN line on stdout

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/check-base-branch-hook-wiring.sh"

PASS=0
FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "  FAIL: helper not found at $HELPER" >&2
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Manifest with PreToolUse Bash matcher invoking enforce-base-branch.py.
WIRED_MANIFEST='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/enforce-base-branch.py" }
        ]
      }
    ]
  }
}'

# Manifest with NO enforce-base-branch matcher (other matchers present).
UNWIRED_MANIFEST='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/block_deletions.py" }
        ]
      }
    ]
  }
}'

# Consumer settings.json wiring the hook from a local path.
WIRED_CONSUMER='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 .claude/hooks/enforce-base-branch.py" }
        ]
      }
    ]
  }
}'

# Consumer settings.json with NO such matcher.
UNWIRED_CONSUMER='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "echo something-else" }
        ]
      }
    ]
  }
}'

# ---- Fixture (a): plugin wires hook, consumer does not ----------------------
A_DIR="$WORKDIR/a"
mkdir -p "$A_DIR/.claude-plugin" "$A_DIR/.claude"
printf '%s\n' "$WIRED_MANIFEST"   > "$A_DIR/.claude-plugin/plugin.json"
printf '%s\n' "$UNWIRED_CONSUMER" > "$A_DIR/.claude/settings.json"

set +e
out_a=$(bash "$HELPER" \
  --plugin-manifest "$A_DIR/.claude-plugin/plugin.json" \
  --consumer-settings "$A_DIR/.claude/settings.json" \
  --expected-base staging 2>&1)
rc_a=$?
set -e

if [ "$rc_a" -ne 0 ]; then
  fail_msg "fixture-a plugin-registered" "expected exit 0, got $rc_a"
elif [ -n "$out_a" ]; then
  fail_msg "fixture-a plugin-registered" "expected silent, got: $out_a"
else
  pass_msg "fixture-a plugin-registered → silent"
fi

# ---- Fixture (b): consumer wires hook, plugin does not ----------------------
B_DIR="$WORKDIR/b"
mkdir -p "$B_DIR/.claude-plugin" "$B_DIR/.claude"
printf '%s\n' "$UNWIRED_MANIFEST" > "$B_DIR/.claude-plugin/plugin.json"
printf '%s\n' "$WIRED_CONSUMER"   > "$B_DIR/.claude/settings.json"

set +e
out_b=$(bash "$HELPER" \
  --plugin-manifest "$B_DIR/.claude-plugin/plugin.json" \
  --consumer-settings "$B_DIR/.claude/settings.json" \
  --expected-base staging 2>&1)
rc_b=$?
set -e

if [ "$rc_b" -ne 0 ]; then
  fail_msg "fixture-b consumer-registered" "expected exit 0, got $rc_b"
elif [ -n "$out_b" ]; then
  fail_msg "fixture-b consumer-registered" "expected silent, got: $out_b"
else
  pass_msg "fixture-b consumer-registered → silent"
fi

# ---- Fixture (c): neither wires the hook -> WARN ----------------------------
C_DIR="$WORKDIR/c"
mkdir -p "$C_DIR/.claude-plugin" "$C_DIR/.claude"
printf '%s\n' "$UNWIRED_MANIFEST" > "$C_DIR/.claude-plugin/plugin.json"
printf '%s\n' "$UNWIRED_CONSUMER" > "$C_DIR/.claude/settings.json"

EXPECTED_LINE='WARN: enforce-base-branch hook not wired in plugin or consumer settings.json; PRs may escape PIPELINE_BASE_BRANCH=staging'

set +e
out_c=$(bash "$HELPER" \
  --plugin-manifest "$C_DIR/.claude-plugin/plugin.json" \
  --consumer-settings "$C_DIR/.claude/settings.json" \
  --expected-base staging 2>&1)
rc_c=$?
set -e

if [ "$rc_c" -ne 0 ]; then
  fail_msg "fixture-c neither wired" "expected exit 0, got $rc_c"
elif [ "$out_c" != "$EXPECTED_LINE" ]; then
  fail_msg "fixture-c neither wired" "expected '$EXPECTED_LINE', got '$out_c'"
else
  pass_msg "fixture-c neither wired → WARN line"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
