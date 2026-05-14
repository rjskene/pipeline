#!/bin/bash
# PreToolUse/PostToolUse hook — logs every tool call to tool-use.log (TSV, always exits 0).
INPUT=$(cat)
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
