#!/bin/bash
set -uo pipefail

# Regression guard for scripts/setup-dogfood-local.sh — the per-host bootstrap
# that registers the working tree as a LOCAL Claude Code marketplace named
# "claude-pipeline-local".
#
# Contract pinned by this test:
#   - The marketplace entry's .installLocation equals the repo working tree root
#     (so ${CLAUDE_PLUGIN_ROOT} resolves to the live tree).
#   - The marketplace entry's .source has discriminator .source == "local" and
#     a .path equal to the repo working tree root.
#   - Idempotence: re-running the script with the same HOME produces a
#     byte-identical known_marketplaces.json (lastUpdated is preserved on
#     subsequent runs when the entry already matches).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/setup-dogfood-local.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

T=$(mktemp -d)
trap "rm -rf $T" EXIT

echo "Test: setup-dogfood-local.sh exists and is executable"
if [ -x "$HELPER" ]; then
  pass_msg "helper present and executable"
else
  fail_msg "helper missing or not executable: $HELPER"
fi

echo "Test: bootstrap into empty HOME registers claude-pipeline-local"
mkdir -p "$T/.claude/plugins"
printf '{}' > "$T/.claude/plugins/known_marketplaces.json"

HOME="$T" bash "$HELPER" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  pass_msg "bootstrap exit 0"
else
  fail_msg "bootstrap exit $RC (expected 0)"
fi

KM="$T/.claude/plugins/known_marketplaces.json"

if [ -f "$KM" ]; then
  pass_msg "known_marketplaces.json exists post-run"
else
  fail_msg "known_marketplaces.json missing post-run"
fi

INSTALL_LOC=$(jq -r '.["claude-pipeline-local"].installLocation // ""' "$KM" 2>/dev/null || echo "")
if [ "$INSTALL_LOC" = "$REPO_ROOT" ]; then
  pass_msg ".installLocation equals repo root"
else
  fail_msg ".installLocation expected $REPO_ROOT, got $INSTALL_LOC"
fi

SOURCE_DISC=$(jq -r '.["claude-pipeline-local"].source.source // ""' "$KM" 2>/dev/null || echo "")
if [ "$SOURCE_DISC" = "local" ]; then
  pass_msg ".source.source == \"local\""
else
  fail_msg ".source.source expected \"local\", got \"$SOURCE_DISC\""
fi

SOURCE_PATH=$(jq -r '.["claude-pipeline-local"].source.path // ""' "$KM" 2>/dev/null || echo "")
if [ "$SOURCE_PATH" = "$REPO_ROOT" ]; then
  pass_msg ".source.path equals repo root"
else
  fail_msg ".source.path expected $REPO_ROOT, got $SOURCE_PATH"
fi

echo "Test: idempotent re-run produces byte-identical known_marketplaces.json"
SNAPSHOT_1=$(cat "$KM")
sleep 1  # ensure clock would tick if script foolishly refreshed lastUpdated
HOME="$T" bash "$HELPER" >/dev/null 2>&1
RC2=$?
SNAPSHOT_2=$(cat "$KM")

if [ "$RC2" -eq 0 ]; then
  pass_msg "second run exit 0"
else
  fail_msg "second run exit $RC2 (expected 0)"
fi

if [ "$SNAPSHOT_1" = "$SNAPSHOT_2" ]; then
  pass_msg "byte-identical known_marketplaces.json on re-run"
else
  fail_msg "known_marketplaces.json changed on re-run (lastUpdated likely refreshed)"
  diff <(printf '%s' "$SNAPSHOT_1") <(printf '%s' "$SNAPSHOT_2") || true
fi

echo "Test: multi-project scrub preserves non-matching projectPath entries"
# Fresh sandbox HOME so we don't collide with the prior test's seeded files.
T2=$(mktemp -d)
mkdir -p "$T2/.claude/plugins"
printf '{}' > "$T2/.claude/plugins/known_marketplaces.json"
IP2="$T2/.claude/plugins/installed_plugins.json"
# Seed three pipeline@claude-pipeline entries: one matching this repo,
# two non-matching synthetic projectPath values under /tmp.
jq -n --arg repo_root "$REPO_ROOT" '
  {
    plugins: {
      "pipeline@claude-pipeline": [
        {projectPath: $repo_root, version: "0.20.1"},
        {projectPath: "/tmp/other-project-a", version: "0.20.1"},
        {projectPath: "/tmp/other-project-b", version: "0.20.1"}
      ]
    }
  }
' > "$IP2"

HOME="$T2" bash "$HELPER" >/dev/null 2>&1
RC3=$?
if [ "$RC3" -eq 0 ]; then
  pass_msg "multi-project run exit 0"
else
  fail_msg "multi-project run exit $RC3 (expected 0)"
fi

REMAINING_LEN=$(jq -r '.plugins["pipeline@claude-pipeline"] | length' "$IP2" 2>/dev/null || echo "-1")
if [ "$REMAINING_LEN" = "2" ]; then
  pass_msg "two non-matching entries preserved"
else
  fail_msg "expected 2 non-matching entries to remain, got $REMAINING_LEN"
fi

REMAINING_PATHS=$(jq -r '.plugins["pipeline@claude-pipeline"] | map(.projectPath) | sort | join(",")' "$IP2" 2>/dev/null || echo "")
EXPECTED_PATHS="/tmp/other-project-a,/tmp/other-project-b"
if [ "$REMAINING_PATHS" = "$EXPECTED_PATHS" ]; then
  pass_msg "surviving entries match non-matching seeds"
else
  fail_msg "expected $EXPECTED_PATHS, got $REMAINING_PATHS"
fi

rm -rf "$T2"

echo "Test: single-project scrub deletes the key (back-compat)"
T3=$(mktemp -d)
mkdir -p "$T3/.claude/plugins"
printf '{}' > "$T3/.claude/plugins/known_marketplaces.json"
IP3="$T3/.claude/plugins/installed_plugins.json"
jq -n --arg repo_root "$REPO_ROOT" '
  {
    plugins: {
      "pipeline@claude-pipeline": [
        {projectPath: $repo_root, version: "0.20.1"}
      ]
    }
  }
' > "$IP3"

HOME="$T3" bash "$HELPER" >/dev/null 2>&1
RC4=$?
if [ "$RC4" -eq 0 ]; then
  pass_msg "single-project run exit 0"
else
  fail_msg "single-project run exit $RC4 (expected 0)"
fi

HAS_KEY=$(jq -r '.plugins | has("pipeline@claude-pipeline")' "$IP3" 2>/dev/null || echo "error")
if [ "$HAS_KEY" = "false" ]; then
  pass_msg "key removed when filtered array is empty"
else
  fail_msg "expected key absent (back-compat single-project), got has=$HAS_KEY"
fi

rm -rf "$T3"

echo
echo "===== test-setup-dogfood-local ====="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
