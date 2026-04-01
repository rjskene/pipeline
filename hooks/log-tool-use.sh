#!/bin/bash
# log-tool-use.sh — Append every tool invocation to a log file for review.
# Logs: timestamp, tool name, and a summary of the input.
# Always exits 0 (never blocks).

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
LOG_DIR="$CLAUDE_PROJECT_DIR/.claude/logs"
LOG_FILE="$LOG_DIR/tool-use.log"

mkdir -p "$LOG_DIR"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

case "$TOOL" in
  Bash)
    SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.command' | head -c 200)
    ;;
  Read|Write|Edit)
    SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // "unknown"')
    ;;
  Glob)
    SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.pattern')
    ;;
  Grep)
    SUMMARY=$(echo "$INPUT" | jq -r '(.tool_input.pattern // "") + " in " + (.tool_input.path // ".")')
    ;;
  Agent)
    SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.description // "no description"')
    ;;
  *)
    SUMMARY=$(echo "$INPUT" | jq -r '.tool_input | tostring' | head -c 200)
    ;;
esac

echo "[$TIMESTAMP] $TOOL: $SUMMARY" >> "$LOG_FILE"

exit 0
