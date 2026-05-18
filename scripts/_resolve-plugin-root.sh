#!/bin/bash
# _resolve-plugin-root.sh — sourceable helper.
#
# Default mode: when CLAUDE_PLUGIN_ROOT is empty/unset (which can happen
# because Claude Code does not consistently export it into the Bash tool's
# subshell), scan ~/.claude/plugins/cache/claude-pipeline/pipeline/*/ and
# export the highest-version directory. Stable releases beat prereleases
# (-rc.N); within each group, `sort -V` picks the top.
#
# Active-project mode (PIPELINE_RESOLVE_MODE=active-project): read
# ~/.claude/plugins/installed_plugins.json (override via
# PIPELINE_INSTALLED_PLUGINS_FILE) and pick the installPath of the pipeline@*
# entry whose projectPath matches $PWD. Falls through to the default cache
# scan when no entry matches, when python3 is unavailable, or when the file
# is missing/malformed. This mode is opt-in and only used by callers that
# need the per-project active plugin (notably doctor.sh's consumer_drift
# check), so the default mode's behavior is byte-stable.
#
# Idempotent. Silent on success. No-op when already set or when no cache exists.
#
# NOTE: the plugin cache path is a Claude Code internal. If Anthropic moves it,
# set PIPELINE_PLUGIN_CACHE_DIR to point at the new location.

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ "${PIPELINE_RESOLVE_MODE:-}" = "active-project" ]; then
  _rpr_plugins_file="${PIPELINE_INSTALLED_PLUGINS_FILE:-${HOME}/.claude/plugins/installed_plugins.json}"
  if [ -f "$_rpr_plugins_file" ] && command -v python3 >/dev/null 2>&1; then
    _rpr_active="$(
      PIPELINE_RPR_PWD="$PWD" \
      PIPELINE_RPR_FILE="$_rpr_plugins_file" \
      python3 -c '
import json, os, sys
try:
    with open(os.environ["PIPELINE_RPR_FILE"]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
pwd = os.environ.get("PIPELINE_RPR_PWD", "")
plugins = data.get("plugins") or {}
matches = []
for key, entries in plugins.items():
    if not key.startswith("pipeline@"):
        continue
    if not isinstance(entries, list):
        continue
    for e in entries:
        if not isinstance(e, dict):
            continue
        if e.get("projectPath") == pwd and e.get("installPath"):
            matches.append((e.get("version", ""), e["installPath"]))
if not matches:
    sys.exit(0)
# Defensive tie-break: highest-version among matches wins.
def vkey(s):
    parts = []
    for tok in s.replace("-", ".").split("."):
        try:
            parts.append((0, int(tok)))
        except ValueError:
            parts.append((1, tok))
    return parts
matches.sort(key=lambda t: vkey(t[0]))
print(matches[-1][1])
' 2>/dev/null
    )"
    if [ -n "$_rpr_active" ] && [ -d "$_rpr_active" ]; then
      export CLAUDE_PLUGIN_ROOT="$_rpr_active"
      unset _rpr_plugins_file _rpr_active
      return 0 2>/dev/null || exit 0
    fi
    unset _rpr_active
  fi
  unset _rpr_plugins_file
  # Fall through to cache scan when active-project lookup yields nothing.
fi

_rpr_cache="${PIPELINE_PLUGIN_CACHE_DIR:-${HOME}/.claude/plugins/cache/claude-pipeline/pipeline}"

if [ ! -d "$_rpr_cache" ]; then
  unset _rpr_cache
  return 0 2>/dev/null || exit 0
fi

_rpr_pick() {
  local d base
  local stable=() pre=()
  for d in "$_rpr_cache"/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    case "$base" in
      *-*) pre+=("$base") ;;
      *)   stable+=("$base") ;;
    esac
  done
  if [ "${#stable[@]}" -gt 0 ]; then
    printf '%s\n' "${stable[@]}" | sort -V | tail -n 1
  elif [ "${#pre[@]}" -gt 0 ]; then
    printf '%s\n' "${pre[@]}" | sort -V | tail -n 1
  fi
}

_rpr_latest="$(_rpr_pick)"
if [ -n "$_rpr_latest" ]; then
  export CLAUDE_PLUGIN_ROOT="$_rpr_cache/$_rpr_latest"
fi

unset -f _rpr_pick
unset _rpr_cache _rpr_latest
