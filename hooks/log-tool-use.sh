#!/bin/bash
# PreToolUse/PostToolUse hook — logs every tool call to tool-use.log (TSV, always exits 0).
# Bound the stdin read so a never-closing stdin cannot wedge the session (#917).
# `timeout` exits 124 on the deadline; `|| true` keeps the hook exit 0, and the
# empty INPUT then flows to the existing jq -r '.tool_name' → empty → clean skip.
INPUT=$(timeout 5 cat || true)
# PIPELINE_LOGS_ENABLED gate (#1616): this hook ships in the published plugin
# manifest, so it is inert unless the flag resolves to exactly "true". Process
# env wins when SET (even "false"); else parse ${CLAUDE_PROJECT_DIR:-.}/pipeline.config
# (last assignment wins; mirrors capture_agent_cost._flag_from_config). Pure bash
# (no grep/sed): the jq-missing PATH sandbox carries only cat/date/mkdir/tr. Runs
# BEFORE the jq-missing branch so gate-off writes nothing, not even hook-errors.log.
# Kept inline (not sourced) because the hook is also copied standalone.
if [ -n "${PIPELINE_LOGS_ENABLED+x}" ]; then
    _logs_flag="$PIPELINE_LOGS_ENABLED"
else
    _logs_flag=""
    _logs_cfg="${CLAUDE_PROJECT_DIR:-.}/pipeline.config"
    _logs_re='^[[:space:]]*(export[[:space:]]+)?PIPELINE_LOGS_ENABLED[[:space:]]*=(.*)$'
    if [ -r "$_logs_cfg" ]; then
        while IFS= read -r _logs_line || [ -n "$_logs_line" ]; do
            [[ "$_logs_line" =~ $_logs_re ]] || continue
            _logs_raw="${BASH_REMATCH[2]}"
            # trim leading whitespace
            _logs_raw="${_logs_raw#"${_logs_raw%%[![:space:]]*}"}"
            # drop a trailing inline comment only when the value is unquoted
            case "$_logs_raw" in \"*|\'*) ;; *) _logs_raw="${_logs_raw%%#*}" ;; esac
            # trim trailing whitespace
            _logs_raw="${_logs_raw%"${_logs_raw##*[![:space:]]}"}"
            if [ "${#_logs_raw}" -ge 2 ]; then
                _logs_q="${_logs_raw:0:1}"
                if { [ "$_logs_q" = '"' ] || [ "$_logs_q" = "'" ]; } && [ "${_logs_raw: -1}" = "$_logs_q" ]; then
                    _logs_raw="${_logs_raw:1:${#_logs_raw}-2}"
                fi
            fi
            _logs_flag="$_logs_raw"
        done < "$_logs_cfg"
    fi
fi
[ "$_logs_flag" = "true" ] || exit 0
if ! command -v jq >/dev/null 2>&1; then
    LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
    mkdir -p "$LOG_DIR"
    printf '%s\tlog-tool-use.sh: jq not found on PATH; skipping tool-use row\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG_DIR/hook-errors.log"
    exit 0
fi
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
SESSION=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION" ] && SESSION="${CLAUDE_SESSION_ID:-unknown}"
LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
LOG_FILE="$LOG_DIR/tool-use.log"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

case "${CLAUDE_HOOK_EVENT_NAME:-}" in
  PreToolUse)  PHASE="pre" ;;
  PostToolUse) PHASE="post" ;;
  *)           PHASE="unknown" ;;
esac

case "$TOOL" in
  Bash)   SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.command' | head -c 200) ;;
  Read|Write|Edit)
          SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // "unknown"') ;;
  Glob)   SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.pattern // "unknown"') ;;
  Grep)   SUMMARY=$(echo "$INPUT" | jq -r '(.tool_input.pattern // "") + " in " + (.tool_input.path // ".")') ;;
  Agent)  SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.description // "no description"') ;;
  Skill)  SKILL_NAME=$(echo "$INPUT" | jq -r '.tool_input.skill // "unknown"'); SUMMARY="skill=${SKILL_NAME}" ;;
  *)      SUMMARY=$(echo "$INPUT" | jq -r '.tool_input | tostring' | head -c 200) ;;
esac

# strip embedded tabs/newlines so TSV stays clean
SUMMARY=$(printf '%s' "$SUMMARY" | tr '\t\n' '  ')

# TSV: ts \t phase \t tool \t session=... \t summary (5 fields since issue #157)
printf '%s\t%s\t%s\tsession=%s\t%s\n' "$TIMESTAMP" "$PHASE" "$TOOL" "$SESSION" "$SUMMARY" >> "$LOG_FILE"
exit 0
