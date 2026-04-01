#!/bin/bash
# queue-status.sh — emit a pipeline status snapshot for auto-polling.
# Usage: bash .claude/scripts/queue-status.sh
# Outputs a fixed-width block intended for consumption by CronCreate auto-status jobs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/pipeline.config"

# Memory stats
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
USED_MEM_MB=$(free -m  | awk '/^Mem:/{print $3}')
AVAIL_MEM_MB=$(free -m | awk '/^Mem:/{print $7}')
MEM_PCT=$(( USED_MEM_MB * 100 / TOTAL_MEM_MB ))

# CPU snapshot (user + system %, single pass)
CPU_PCT=$(top -bn1 | awk '/^%Cpu/{gsub(/[^0-9.]/, " "); split($0, a); printf "%d", a[1]+a[2]}' 2>/dev/null || echo "n/a")

# Active agent windows in tmux dev session
ACTIVE_ISSUES=$(tmux list-windows -t dev -F '#{window_name}' 2>/dev/null | grep '^issue-' | sed 's/issue-//' | tr '\n' ' ' || true)
ACTIVE_COUNT=$(echo "${ACTIVE_ISSUES}" | wc -w || echo 0)

# Latest queue log
QUEUE_LOG=$(ls -t "${REPO_ROOT}/.claude/logs"/queue-*.log 2>/dev/null | head -1 || true)
TOTAL_LAUNCHED=0
COMPLETED=0
if [ -n "${QUEUE_LOG:-}" ] && [ -f "${QUEUE_LOG}" ]; then
  TOTAL_LAUNCHED=$(grep -c "Launching agent" "${QUEUE_LOG}" 2>/dev/null || echo 0)
  COMPLETED=$(grep -c "finished — outcome" "${QUEUE_LOG}" 2>/dev/null || echo 0)
fi

# PR links — use slug extracted from the queue log line, look up PR by branch name
# Format: [HH:MM:SS] Launching agent for issue #N (slug)...
# Format: [HH:MM:SS] Agent for issue #N finished — outcome: pr-open
PR_LINKS=""
if [ -n "${QUEUE_LOG:-}" ] && [ -f "${QUEUE_LOG}" ]; then
  COMPLETED_WITH_PR=$(grep "finished — outcome: pr-open" "${QUEUE_LOG}" 2>/dev/null \
    | grep -oP 'issue #\K[0-9]+' || true)
  for issue_num in ${COMPLETED_WITH_PR}; do
    # Extract slug from the "Launching agent" line for this issue
    SLUG=$(grep "Launching agent for issue #${issue_num} " "${QUEUE_LOG}" | head -1 \
      | grep -oP '\(\K[^)]+' || true)
    PR_URL=""
    if [ -n "${SLUG}" ]; then
      PR_URL=$(gh pr list --repo "${PIPELINE_REPO}" --head "feature/${SLUG}" \
        --json url --jq '.[0].url' 2>/dev/null || true)
    fi
    [ -n "${PR_URL}" ] && PR_LINKS="${PR_LINKS}  #${issue_num}: ${PR_URL}\n"
  done
fi

# Memory warnings
MEM_WARNING=""
PER_AGENT=300
if [ "${MEM_PCT}" -ge 90 ] 2>/dev/null; then
  SAFE_AGENTS=$(( (TOTAL_MEM_MB * 90 / 100 - USED_MEM_MB) / PER_AGENT ))
  [ "${SAFE_AGENTS}" -lt 1 ] && SAFE_AGENTS=1
  MEM_WARNING="CRITICAL: Memory at ${MEM_PCT}% — strongly recommend reducing MAX_AGENTS to ${SAFE_AGENTS} immediately."
elif [ "${MEM_PCT}" -ge 85 ] 2>/dev/null; then
  SAFE_AGENTS=$(( (TOTAL_MEM_MB * 85 / 100 - USED_MEM_MB) / PER_AGENT ))
  [ "${SAFE_AGENTS}" -lt 1 ] && SAFE_AGENTS=1
  MEM_WARNING="WARNING: Memory at ${MEM_PCT}% — suggest reducing MAX_AGENTS to ${SAFE_AGENTS}."
fi

echo "========================================"
echo "PIPELINE AUTO-UPDATE — $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo "  Active agents : ${ACTIVE_COUNT} (${ACTIVE_ISSUES:-none})"
echo "  Completed     : ${COMPLETED} / ${TOTAL_LAUNCHED} launched"
echo "  Queued        : $(( TOTAL_LAUNCHED - COMPLETED > 0 ? TOTAL_LAUNCHED - COMPLETED : 0 )) remaining"
echo "  CPU usage     : ${CPU_PCT}%"
echo "  Memory        : ${MEM_PCT}% used (${AVAIL_MEM_MB} MB available)"
if [ -n "${PR_LINKS}" ]; then
  echo "  PRs created   :"
  printf "%b" "${PR_LINKS}"
fi
if [ -n "${MEM_WARNING}" ]; then
  echo ""
  echo "  *** ${MEM_WARNING} ***"
fi
echo "========================================"
