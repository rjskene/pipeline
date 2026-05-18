#!/usr/bin/env bash
#
# scripts/check-base-branch-hook-wiring.sh -- housekeeping advisory used by
# /pipeline:run to warn when the enforce-base-branch.py PreToolUse hook is
# wired in NEITHER the plugin manifest (.claude-plugin/plugin.json) NOR the
# consumer's local settings (.claude/settings.json).
#
# Defense-in-depth: the hook blocks `gh pr create` invocations that omit
# --base or target the wrong branch. If both wiring surfaces drop it, PRs
# created by spawned agents can silently escape PIPELINE_BASE_BRANCH and
# target the repo's default branch.
#
# Non-fatal advisory: always exits 0. Prints nothing when at least one side
# wires the hook; prints a single WARN line on stdout when neither does.
#
# /pipeline:run cannot fix consumer settings.json -- #215 tracks render-on-
# install. This helper is the visibility surface in the meantime.
#
# Usage:
#   bash scripts/check-base-branch-hook-wiring.sh \
#     --plugin-manifest <path> \
#     --consumer-settings <path> \
#     --expected-base <name>

set -uo pipefail

PLUGIN_MANIFEST=""
CONSUMER_SETTINGS=""
EXPECTED_BASE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-manifest)   PLUGIN_MANIFEST="$2"; shift 2 ;;
    --consumer-settings) CONSUMER_SETTINGS="$2"; shift 2 ;;
    --expected-base)     EXPECTED_BASE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Returns 0 if the given JSON file contains a PreToolUse Bash matcher whose
# command string mentions `enforce-base-branch.py`. Returns 1 otherwise
# (including when the file is missing or malformed -- advisory, not strict).
file_wires_hook() {
  local f="$1"
  [ -f "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Pull every PreToolUse hook command string, filter for Bash matchers, and
  # grep for the hook script name. A single match is enough.
  jq -r '
    (.hooks.PreToolUse // [])[]
    | select((.matcher // "") == "Bash")
    | (.hooks // [])[]
    | (.command // "")
  ' "$f" 2>/dev/null | grep -q 'enforce-base-branch\.py' || return 1
  return 0
}

plugin_wired=1
consumer_wired=1
file_wires_hook "$PLUGIN_MANIFEST"   && plugin_wired=0
file_wires_hook "$CONSUMER_SETTINGS" && consumer_wired=0

if [ "$plugin_wired" -ne 0 ] && [ "$consumer_wired" -ne 0 ]; then
  echo "WARN: enforce-base-branch hook not wired in plugin or consumer settings.json; PRs may escape PIPELINE_BASE_BRANCH=${EXPECTED_BASE}"
fi

exit 0
