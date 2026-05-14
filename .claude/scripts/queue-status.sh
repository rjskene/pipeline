#!/bin/bash
# queue-status.sh — emit a pipeline status snapshot for the queue runner and manual checks.
# Usage: bash .claude/scripts/queue-status.sh [--queue-log <path>]
# Outputs a pipeline status snapshot for the queue runner and manual checks.

set -uo pipefail
# NOTE: set -e intentionally omitted. This is a reporter script called from
# the queue runner's poll loop. Any transient failure (tmux window gone, gh API
# timeout, process exited mid-stat) must NOT propagate — the queue runner runs
# under set -euo pipefail and a non-zero exit here kills the entire queue.

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

# Parse --queue-log argument
QUEUE_LOG_ARG=""
if [ "${1:-}" = "--queue-log" ] && [ -n "${2:-}" ]; then
  QUEUE_LOG_ARG="$2"
fi

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

# Queue log — use argument or auto-detect latest
QUEUE_LOG=""
if [ -n "${QUEUE_LOG_ARG}" ] && [ -f "${QUEUE_LOG_ARG}" ]; then
  QUEUE_LOG="${QUEUE_LOG_ARG}"
else
  QUEUE_LOG=$(ls -t "${REPO_ROOT}/.claude/logs"/queue-*.log 2>/dev/null | head -1 || true)
fi

TOTAL_LAUNCHED=0
COMPLETED=0
if [ -n "${QUEUE_LOG:-}" ] && [ -f "${QUEUE_LOG}" ]; then
  TOTAL_LAUNCHED=$(grep -c "Launching agent" "${QUEUE_LOG}" 2>/dev/null || echo 0)
  COMPLETED=$(grep -c "finished — outcome" "${QUEUE_LOG}" 2>/dev/null || echo 0)
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

# Build per-agent detail rows
NOW=$(date +%s)
declare -a AGENT_ISSUES=()
declare -A AGENT_STATUS=()
declare -A AGENT_SLUG=()
declare -A AGENT_RUNTIME=()
declare -A AGENT_CPU=()
declare -A AGENT_MEM=()
declare -A AGENT_PR=()

if [ -n "${QUEUE_LOG:-}" ] && [ -f "${QUEUE_LOG}" ]; then
  # Extract all launched issue numbers (in order)
  while IFS= read -r line; do
    issue_num=$(echo "$line" | grep -oP 'issue #\K[0-9]+' || true)
    [ -z "$issue_num" ] && continue
    AGENT_ISSUES+=("$issue_num")

    # Extract slug
    slug=$(echo "$line" | grep -oP '\(\K[^)]+' || true)
    AGENT_SLUG[$issue_num]="$slug"
  done < <(grep "Launching agent for issue" "${QUEUE_LOG}" 2>/dev/null)

  for issue_num in "${AGENT_ISSUES[@]}"; do
    # Determine status
    finished_line=$(grep "issue #${issue_num} finished — outcome:" "${QUEUE_LOG}" 2>/dev/null | tail -1 || true)
    if [ -n "$finished_line" ]; then
      outcome=$(echo "$finished_line" | grep -oP 'outcome: \K.*' || echo "unknown")
      AGENT_STATUS[$issue_num]="$outcome"
      AGENT_RUNTIME[$issue_num]="—"
      AGENT_CPU[$issue_num]="—"
      AGENT_MEM[$issue_num]="—"
    elif tmux list-windows -t dev -F '#{window_name}' 2>/dev/null | grep -q "^issue-${issue_num}$"; then
      AGENT_STATUS[$issue_num]="running"

      # Runtime from epoch in launch line
      launch_epoch=$(grep "Launching agent for issue #${issue_num}" "${QUEUE_LOG}" | head -1 \
        | grep -oP '\[\K[0-9]{10,}(?=\])' || true)
      if [ -n "$launch_epoch" ]; then
        runtime_secs=$(( NOW - launch_epoch ))
        if [ "$runtime_secs" -ge 3600 ]; then
          hours=$(( runtime_secs / 3600 ))
          mins=$(( (runtime_secs % 3600) / 60 ))
          AGENT_RUNTIME[$issue_num]="${hours}h ${mins}m"
        else
          mins=$(( runtime_secs / 60 ))
          AGENT_RUNTIME[$issue_num]="${mins}m"
        fi
      else
        AGENT_RUNTIME[$issue_num]="—"
      fi

      # Per-agent CPU% and memory via tmux pane PID
      PANE_PID=$(tmux list-panes -t "dev:issue-${issue_num}" -F '#{pane_pid}' 2>/dev/null | head -1 || true)
      if [ -n "$PANE_PID" ]; then
        # Sum CPU% and RSS across child processes
        read -r total_cpu total_rss < <(ps -o pcpu=,rss= --ppid "$PANE_PID" 2>/dev/null \
          | awk '{cpu+=$1; rss+=$2} END {printf "%.0f %d", cpu, rss}' || echo "0 0")
        AGENT_CPU[$issue_num]="${total_cpu}%"
        AGENT_MEM[$issue_num]="$(( total_rss / 1024 ))"
      else
        AGENT_CPU[$issue_num]="—"
        AGENT_MEM[$issue_num]="—"
      fi
    else
      AGENT_STATUS[$issue_num]="queued"
      AGENT_RUNTIME[$issue_num]="—"
      AGENT_CPU[$issue_num]="—"
      AGENT_MEM[$issue_num]="—"
    fi

    # PR URL for completed agents with pr-open outcome
    if [ "${AGENT_STATUS[$issue_num]}" = "pr-open" ]; then
      slug="${AGENT_SLUG[$issue_num]}"
      PR_URL=""
      if [ -n "${slug}" ]; then
        PR_URL=$(gh pr list --repo "${PIPELINE_REPO}" --head "feature/${slug}" \
          --json url --jq '.[0].url' 2>/dev/null || true)
      fi
      AGENT_PR[$issue_num]="${PR_URL:-—}"
    else
      AGENT_PR[$issue_num]="—"
    fi
  done
fi

# Count statuses for summary
completed_count=0
active_count=0
queued_count=0
for issue_num in "${AGENT_ISSUES[@]}"; do
  case "${AGENT_STATUS[$issue_num]}" in
    running) active_count=$((active_count + 1)) ;;
    queued)  queued_count=$((queued_count + 1)) ;;
    *)       completed_count=$((completed_count + 1)) ;;
  esac
done

# Output
echo "========================================"
echo "PIPELINE STATUS — $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo "System: CPU ${CPU_PCT}% | Memory ${MEM_PCT}% (${AVAIL_MEM_MB} MB avail)"
echo "========================================"

if [ ${#AGENT_ISSUES[@]} -gt 0 ]; then
  printf " %-7s %-13s %-10s %-6s %-8s %s\n" "Issue" "Status" "Runtime" "CPU%" "Mem MB" "PR"
  echo "----------------------------------------------------------------"
  for issue_num in "${AGENT_ISSUES[@]}"; do
    printf " %-7s %-13s %-10s %-6s %-8s %s\n" \
      "#${issue_num}" \
      "${AGENT_STATUS[$issue_num]}" \
      "${AGENT_RUNTIME[$issue_num]}" \
      "${AGENT_CPU[$issue_num]}" \
      "${AGENT_MEM[$issue_num]}" \
      "${AGENT_PR[$issue_num]}"
  done
  echo "================================================================"
  total=${#AGENT_ISSUES[@]}
  echo "Completed: ${completed_count} / ${total} | Active: ${active_count} | Queued: ${queued_count}"
else
  echo "  Active agents : ${ACTIVE_COUNT} (${ACTIVE_ISSUES:-none})"
  echo "  Completed     : ${COMPLETED} / ${TOTAL_LAUNCHED} launched"
fi

if [ -n "${MEM_WARNING}" ]; then
  echo ""
  echo "*** ${MEM_WARNING} ***"
fi
echo "========================================"
