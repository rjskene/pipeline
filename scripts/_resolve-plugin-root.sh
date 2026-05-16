#!/bin/bash
# _resolve-plugin-root.sh — sourceable helper.
#
# When CLAUDE_PLUGIN_ROOT is empty/unset (which can happen because Claude Code
# does not consistently export it into the Bash tool's subshell), scan
# ~/.claude/plugins/cache/claude-pipeline/pipeline/*/ and export the highest
# version directory. Stable releases beat prereleases (-rc.N); within each
# group, `sort -V` picks the top.
#
# Idempotent. Silent on success. No-op when already set or when no cache exists.
#
# NOTE: the plugin cache path is a Claude Code internal. If Anthropic moves it,
# set PIPELINE_PLUGIN_CACHE_DIR to point at the new location.

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  return 0 2>/dev/null || exit 0
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
