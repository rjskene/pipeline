#!/bin/bash
# platform.sh — sourceable harness-detection primitive (issue #980, Leg 1 of the
# Codex dual-target migration). Exports PIPELINE_HARNESS=claude|codex.
#
# This is the SINGLE source of platform divergence: every later platform branch
# in scripts and skills keys off $PIPELINE_HARNESS; nothing else hard-codes a
# harness. Detection precedence (highest first):
#
#   1. pipeline.config `PIPELINE_HARNESS` override (authoritative). Read by GREP,
#      NOT by sourcing — the config carries host-specific `$(...)` that must never
#      execute during detection. Last assignment wins; one layer of surrounding
#      quotes is stripped.
#   2. Env sniff: CODEX_HOME present -> codex; else CLAUDE_PLUGIN_ROOT present -> claude.
#   3. Default `claude`.
#
# Sourced into scripts running `set -e`, so every command MUST keep exit status 0
# (a bare `x="$(grep ... )"` that matches nothing returns 1 and would abort the
# host under `set -e` — hence the `|| true` guards below).
#
# Idempotent: re-sourcing recomputes the same value. Silent on success.

_pf_harness=""

# --- 1. config override (grep, never source) ---
# Read the LAST `PIPELINE_HARNESS=` assignment (indented + spaces-around-= allowed)
# from the project's pipeline.config. CLAUDE_PROJECT_DIR is the harness-provided
# project root; fall back to $PWD when it is unset.
_pf_config="${CLAUDE_PROJECT_DIR:-$PWD}/pipeline.config"
if [ -f "$_pf_config" ]; then
  _pf_line="$(grep -E '^[[:space:]]*PIPELINE_HARNESS[[:space:]]*=' "$_pf_config" 2>/dev/null | tail -n 1 || true)"
  if [ -n "$_pf_line" ]; then
    # Strip everything up to and including the first `=`, surrounding whitespace,
    # and one layer of matching single/double quotes.
    _pf_val="${_pf_line#*=}"
    # trim leading/trailing whitespace
    _pf_val="${_pf_val#"${_pf_val%%[![:space:]]*}"}"
    _pf_val="${_pf_val%"${_pf_val##*[![:space:]]}"}"
    # strip one matching quote pair
    case "$_pf_val" in
      \"*\") _pf_val="${_pf_val#\"}"; _pf_val="${_pf_val%\"}" ;;
      \'*\') _pf_val="${_pf_val#\'}"; _pf_val="${_pf_val%\'}" ;;
    esac
    [ -n "$_pf_val" ] && _pf_harness="$_pf_val"
  fi
  unset _pf_line _pf_val
fi
unset _pf_config

# --- 2. env sniff (only when no override) ---
if [ -z "$_pf_harness" ]; then
  if [ -n "${CODEX_HOME:-}" ]; then
    _pf_harness="codex"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    _pf_harness="claude"
  fi
fi

# --- 3. default ---
[ -n "$_pf_harness" ] || _pf_harness="claude"

export PIPELINE_HARNESS="$_pf_harness"
unset _pf_harness
