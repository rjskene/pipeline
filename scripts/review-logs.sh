#!/bin/bash
set -euo pipefail

# Review agent session logs for errors and key events.
# Usage: bash .claude/scripts/review-logs.sh [issue-number|--subagents [filter]]
#   No args: summarize all logs
#   With issue number: show details for that issue's latest log
#   --subagents: show subagent activity (optional filter fragment to grep)

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="${REPO_ROOT}/.claude/logs"

if [ ! -d "$LOG_DIR" ] || [ -z "$(ls -A "$LOG_DIR" 2>/dev/null)" ]; then
  echo "No logs found in $LOG_DIR"
  exit 0
fi

# Error patterns to search for
ERROR_PATTERNS="ERROR|FAIL|error:|failed|permission denied|EACCES|ENOENT|fatal:|panic:|Traceback|denied|refused|timed out|timeout|OOM|killed|Cannot|could not"

if [ "${1:-}" = "--subagents" ]; then
  SUBAGENT_LOG="${REPO_ROOT}/.claude/logs/subagents.log"
  SUBAGENTS_DIR="${REPO_ROOT}/.claude/logs/subagents"
  FILTER="${2:-}"

  if [ ! -f "$SUBAGENT_LOG" ]; then
    echo "No subagent logs found"
    exit 0
  fi

  if [ -n "$FILTER" ]; then
    echo "=== Subagent logs matching '$FILTER' ==="
    grep -i "$FILTER" "$SUBAGENT_LOG" | while IFS=$'\t' read -r ts session desc result_chars tokens dur_ms filename; do
      echo ""
      printf "%-24s %-40s %-8s %-8s\n" "$ts" "${desc:0:40}" "$tokens" "$dur_ms"
      JSON_FILE="${SUBAGENTS_DIR}/${filename}"
      if [ -f "$JSON_FILE" ]; then
        echo "--- ${filename} ---"
        cat "$JSON_FILE"
      fi
    done
  else
    echo "=== All subagent activity ==="
    printf "%-24s %-40s %-8s %-8s\n" "Time" "Description" "Tokens" "Dur(ms)"
    echo "-----------------------------------------------------------------------"
    cat "$SUBAGENT_LOG" | while IFS=$'\t' read -r ts session desc result_chars tokens dur_ms filename; do
      printf "%-24s %-40s %-8s %-8s\n" "$ts" "${desc:0:40}" "$tokens" "$dur_ms"
    done
  fi
  exit 0
fi

if [ -n "${1:-}" ]; then
  # Show details for a specific issue
  ISSUE_NUM="$1"
  LOG_FILE=$(ls -t "$LOG_DIR"/issue-"${ISSUE_NUM}"-*.log 2>/dev/null | head -1)
  if [ -z "$LOG_FILE" ]; then
    echo "No logs found for issue #${ISSUE_NUM}"
    exit 0
  fi
  echo "=== Latest log for issue #${ISSUE_NUM}: $(basename "$LOG_FILE") ==="
  echo ""
  echo "--- Errors & warnings ---"
  grep -inE "$ERROR_PATTERNS" "$LOG_FILE" | head -50 || echo "  (none found)"
  echo ""
  echo "--- PR / merge activity ---"
  grep -iE "pr created|pr merged|merge|pull request|auto-merge" "$LOG_FILE" | head -20 || echo "  (none found)"
  echo ""
  echo "--- Session boundaries ---"
  grep -E "^=== Session|Script started|Script done" "$LOG_FILE" || echo "  (none found)"
  echo ""
  echo "Full log: $LOG_FILE"
else
  # Summarize all logs
  echo "AGENT SESSION LOGS — $(date +%Y-%m-%d)"
  echo "======================================================================="
  printf "%-12s %-22s %-8s %-8s %s\n" "Issue" "Timestamp" "Errors" "Lines" "File"
  echo "-----------------------------------------------------------------------"
  for LOG_FILE in $(ls -t "$LOG_DIR"/issue-*.log 2>/dev/null); do
    BASENAME=$(basename "$LOG_FILE")
    # Extract issue number and timestamp from filename
    ISSUE=$(echo "$BASENAME" | sed 's/issue-\([0-9]*\)-.*/\1/')
    TS=$(echo "$BASENAME" | sed 's/issue-[0-9]*-\(.*\)\.log/\1/')
    LINES=$(wc -l < "$LOG_FILE")
    ERRORS=$(grep -ciE "$ERROR_PATTERNS" "$LOG_FILE" 2>/dev/null || echo "0")
    printf "%-12s %-22s %-8s %-8s %s\n" "#${ISSUE}" "$TS" "$ERRORS" "$LINES" "$BASENAME"
  done
  echo "======================================================================="
  echo ""
  echo "View details: bash .claude/scripts/review-logs.sh <issue-number>"

  # Subagent activity summary
  SUBAGENT_LOG="${REPO_ROOT}/.claude/logs/subagents.log"
  if [ -f "$SUBAGENT_LOG" ]; then
    echo ""
    echo "SUBAGENTS — last 20"
    echo "======================================================================="
    printf "%-24s %-40s %-8s %-8s\n" "Time" "Description" "Tokens" "Dur(ms)"
    echo "-----------------------------------------------------------------------"
    tail -20 "$SUBAGENT_LOG" | while IFS=$'\t' read -r ts session desc result_chars tokens dur_ms filename; do
      printf "%-24s %-40s %-8s %-8s\n" "$ts" "${desc:0:40}" "$tokens" "$dur_ms"
    done
    echo "======================================================================="
  fi
fi
