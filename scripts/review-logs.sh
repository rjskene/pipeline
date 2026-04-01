#!/bin/bash
set -euo pipefail

# Review agent session logs for errors and key events.
# Usage: bash .claude/scripts/review-logs.sh [issue-number]
#   No args: summarize all logs
#   With issue number: show details for that issue's latest log

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="${REPO_ROOT}/.claude/logs"

if [ ! -d "$LOG_DIR" ] || [ -z "$(ls -A "$LOG_DIR" 2>/dev/null)" ]; then
  echo "No logs found in $LOG_DIR"
  exit 0
fi

# Error patterns to search for
ERROR_PATTERNS="ERROR|FAIL|error:|failed|permission denied|EACCES|ENOENT|fatal:|panic:|Traceback|denied|refused|timed out|timeout|OOM|killed|Cannot|could not"

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
  echo "================================================================"
  printf "%-12s %-22s %-8s %-8s %s\n" "Issue" "Timestamp" "Errors" "Lines" "File"
  echo "----------------------------------------------------------------"
  for LOG_FILE in $(ls -t "$LOG_DIR"/issue-*.log 2>/dev/null); do
    BASENAME=$(basename "$LOG_FILE")
    # Extract issue number and timestamp from filename
    ISSUE=$(echo "$BASENAME" | sed 's/issue-\([0-9]*\)-.*/\1/')
    TS=$(echo "$BASENAME" | sed 's/issue-[0-9]*-\(.*\)\.log/\1/')
    LINES=$(wc -l < "$LOG_FILE")
    ERRORS=$(grep -ciE "$ERROR_PATTERNS" "$LOG_FILE" 2>/dev/null || echo "0")
    printf "%-12s %-22s %-8s %-8s %s\n" "#${ISSUE}" "$TS" "$ERRORS" "$LINES" "$BASENAME"
  done
  echo "================================================================"
  echo ""
  echo "View details: bash .claude/scripts/review-logs.sh <issue-number>"
fi
