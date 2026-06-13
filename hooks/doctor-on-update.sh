#!/usr/bin/env bash
# doctor-on-update.sh — thin, READ-ONLY plugin-version-change detector (#1038).
#
# Wired into BOTH UserPromptSubmit (PRIMARY — fires on the operator's very next
# message, same session, no lag after /reload-plugins) and SessionStart
# (BACKSTOP — fresh sessions). On every invocation it compares the resolved
# plugin version against a cached last-seen marker:
#   - UNCHANGED  -> CHEAP silent no-op. Pure string compare, NO network, no gh,
#                   no doctor, no marker rewrite. (UserPromptSubmit fires on
#                   EVERY prompt, so the no-op path must be ultra-cheap.)
#   - CHANGED    -> emit stdout-JSON injection:
#                     hookSpecificOutput.additionalContext (model-facing
#                       directive to run the /pipeline:doctor reconcile);
#                     systemMessage (operator-facing banner);
#                   then update the marker so it fires ONCE per update.
#
# The hook is a DETECTOR, not a mutator: all GitHub/config mutation stays inside
# the visible, gated /pipeline:doctor run (--fix labels + --fix config). The
# ONLY thing this hook writes is the version marker, which lives under the
# .claude/logs/ runtime allow-list.
#
# FAIL-OPEN everywhere (mirrors dev/hooks/dogfood-refresh.sh): exit 0 on EVERY
# error mode (missing jq, corrupt plugin.json, unset CLAUDE_PLUGIN_ROOT, missing
# marker dir, unreadable marker). The detector must NEVER block a prompt or a
# session.
#
# Opt-out: PIPELINE_DOCTOR_ON_UPDATE_ENABLED (default true). Set false to disable.

set -uo pipefail

# Bounded stdin drain so a never-closing stdin can't wedge the session
# (mirrors the stdin-guard discipline). We don't need the payload's contents
# beyond the event name, so swallow-with-timeout is sufficient.
_evt_stdin=""
_evt_stdin="$(timeout 5 cat 2>/dev/null || true)"

# 1. Opt-out gate (default true). Any error below this point exits 0.
if [ "${PIPELINE_DOCTOR_ON_UPDATE_ENABLED:-true}" != "true" ]; then
  exit 0
fi

# 2. Resolve the plugin manifest path. Unset/empty CLAUDE_PLUGIN_ROOT -> no-op.
_plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$_plugin_root" ] || exit 0
_manifest="$_plugin_root/.claude-plugin/plugin.json"
[ -f "$_manifest" ] || exit 0

# 3. Extract the version. Prefer jq; fall back to a sed/grep extractor so hosts
#    without jq still work. Either path that yields an empty/garbage version
#    exits 0 (fail-open).
_cur_ver=""
if command -v jq >/dev/null 2>&1; then
  _cur_ver="$(jq -r '.version // empty' "$_manifest" 2>/dev/null || true)"
fi
if [ -z "$_cur_ver" ]; then
  _cur_ver="$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$_manifest" 2>/dev/null | head -1 || true)"
fi
# Validate the shape (digits/dots/-/alnum). Anything else (e.g. parsed from a
# corrupt manifest) is treated as unresolved -> fail-open no-op.
case "$_cur_ver" in
  ""|*[!0-9A-Za-z._-]*) exit 0 ;;
esac

# 4. Resolve the marker home under the .claude/logs/ runtime allow-list.
_proj_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
_marker_dir="$_proj_dir/.claude/logs"
_marker="$_marker_dir/.doctor-on-update-version"

# 5. Cheap no-op: read the cached marker and string-compare. Equal -> exit 0
#    with NO injection and NO marker rewrite (the dominant hot path).
_last_ver=""
if [ -f "$_marker" ]; then
  _last_ver="$(cat "$_marker" 2>/dev/null || true)"
fi
if [ "$_last_ver" = "$_cur_ver" ]; then
  exit 0
fi

# 6. CHANGED (or first run, where _last_ver is empty). Emit the injection.
#    Resolve the live event name so one script serves both registrations; fall
#    back to UserPromptSubmit (the primary trigger) when unknown.
_event="${CLAUDE_HOOK_EVENT:-}"
if [ -z "$_event" ] && command -v jq >/dev/null 2>&1; then
  _event="$(printf '%s' "$_evt_stdin" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
fi
[ -n "$_event" ] || _event="UserPromptSubmit"

_from="${_last_ver:-none}"
_directive="The pipeline plugin was just updated (v${_from} -> v${_cur_ver}). Run the doctor reconcile now to seed any new GitHub labels and pick up new PIPELINE_* config knobs, then relay the change report to the operator: run \`/pipeline:doctor --fix config ${_from} ${_cur_ver}\` (envvar reconcile — append-missing, never-overwrite) AND \`/pipeline:doctor --fix labels\` (idempotent label seed). Surface any 'needs your value' keys and remaining warn/fail lines."
_banner="pipeline updated v${_from} -> v${_cur_ver} — reconciling labels + envvars; running /pipeline:doctor"

# Build the JSON safely (jq when available; a hand-escaped fallback otherwise).
if command -v jq >/dev/null 2>&1; then
  jq -cn \
    --arg event "$_event" \
    --arg ctx "$_directive" \
    --arg banner "$_banner" \
    '{hookSpecificOutput:{hookEventName:$event, additionalContext:$ctx}, systemMessage:$banner}' \
    2>/dev/null || true
else
  # Minimal manual JSON escaping (backslash, double-quote) for the fallback path.
  _esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"},"systemMessage":"%s"}\n' \
    "$(_esc "$_event")" "$(_esc "$_directive")" "$(_esc "$_banner")"
fi

# 7. Update the marker so we fire ONCE per update. Fail-open: any error here
#    (unwritable dir, read-only fs) must NOT block the prompt/session.
{ mkdir -p "$_marker_dir" && printf '%s' "$_cur_ver" > "$_marker"; } 2>/dev/null || true

exit 0
