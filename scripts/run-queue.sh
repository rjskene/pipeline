#!/bin/bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

# --add mode: append issues to a running queue's pending file
if [ "${1:-}" = "--add" ]; then
  shift
  REPO_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
  PENDING_FILE="${REPO_ROOT}/.claude/logs/queue-pending.txt"
  # Resolve plugin root so we can source _logging.sh for the gate predicate.
  : "${CLAUDE_PLUGIN_ROOT:?ERROR: CLAUDE_PLUGIN_ROOT unset; cannot resolve _logging.sh}"
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/scripts/_logging.sh"
  if [ $# -eq 0 ]; then
    echo "Usage: bash $0 --add <issue1> <issue2> ..."
    exit 1
  fi
  if pipeline_logging_enabled; then
    for issue in "$@"; do
      echo "$issue" >> "$PENDING_FILE"
    done
    echo "Added $# issue(s) to pending queue: $*"
    echo "Pending file: ${PENDING_FILE}"
  else
    echo "Added $# issue(s) to pending queue (logging disabled; not persisted): $*"
  fi
  exit 0
fi

# --ci-fix mode: re-dispatch execute-issue-plan inside an existing
# feature worktree to fix a red CI run. Does NOT open a new PR; the
# executor pushes a follow-up commit to the existing branch.
if [ "${1:-}" = "--ci-fix" ]; then
  shift
  if [ $# -lt 2 ]; then
    echo "Usage: $0 --ci-fix <issue> <log-path>" >&2
    exit 1
  fi
  CI_FIX_ISSUE="$1"; CI_FIX_LOG="$2"
  REPO_ROOT_CI_FIX="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
  # shellcheck disable=SC1091
  source "${REPO_ROOT_CI_FIX}/pipeline.config"
  # Accept BOTH bare `wt-<N>` and slugged `wt-<N>-<slug>` basenames (sibling
  # of #365's cleanup-worktree.sh fix). The exact-or-prefix predicate on the
  # basename also blocks substring collisions (issue 4 != wt-42, 42 != wt-481).
  WT_PATH=$(git worktree list --porcelain \
    | awk -v p="${PIPELINE_WORKTREE_PREFIX}-${CI_FIX_ISSUE}" \
        '/^worktree / {
           base = $2
           sub(/.*\//, "", base)
           if (base == p || base ~ "^"p"-") { print $2; exit }
         }')
  if [ -z "$WT_PATH" ] || [ ! -d "$WT_PATH" ]; then
    echo "ERROR: No worktree for issue #${CI_FIX_ISSUE} (basename ${PIPELINE_WORKTREE_PREFIX}-${CI_FIX_ISSUE} or ${PIPELINE_WORKTREE_PREFIX}-${CI_FIX_ISSUE}-*)" >&2
    exit 1
  fi
  # Tighten the sed (-n + p flag) so bare `wt-<N>` produces empty output
  # instead of leaving the input unchanged; fall back to `issue-<N>` when
  # there's no slug component, mirroring the orchestrator's default.
  SLUG=$(basename "$WT_PATH" | sed -n "s/^${PIPELINE_WORKTREE_PREFIX}-${CI_FIX_ISSUE}-\(.*\)/\1/p")
  SLUG="${SLUG:-issue-${CI_FIX_ISSUE}}"
  export PIPELINE_CI_FIX_CONTEXT="$CI_FIX_LOG"
  : "${CLAUDE_PLUGIN_ROOT:?ERROR: CLAUDE_PLUGIN_ROOT unset; cannot resolve sibling spawn-claude.sh}"
  exec bash "${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh" \
    --dangerously-skip-permissions \
    --skill execute-issue-plan \
    "$WT_PATH" "$CI_FIX_ISSUE" "$SLUG" tmux
fi

# Run from the consumer repo root (so `$(pwd)/pipeline.config` resolves), or
# export PIPELINE_PROJECT_ROOT to override the lookup directory.
source "${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config"

# Orchestrate multiple agent sessions with concurrency limits.
# Launches up to MAX_CONCURRENT agents at a time, polls for completion,
# and launches the next queued issue when a slot opens.
#
# fullsend invokes this once per wave with only that wave's issue numbers;
# cross-wave serialization and the inter-wave `git pull` are enforced by the
# fullsend loop, not here -- do NOT pass multiple waves' issues in one
# invocation (#626).
#
# Usage:
#   bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] [--skill <name>] <issue1> <issue2> ...
#   bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh --add <issue1> <issue2> ...
#
# The --add flag appends issues to a running queue via a watch file.
#
# Must be run inside a tmux session (the queue runner uses window 0,
# agents spawn in new windows).
#
# Queue log is written to .claude/logs/queue-YYYYMMDD-HHMMSS.log

SKIP_PERMS=""
SKILL_FLAG=""
MANUAL_MERGE_FLAG=""
# Loop-based parser: each flag may appear anywhere before/among the issue
# numbers. --manual-merge in particular must be consumable from any argv
# position (`FULL SEND --manual-merge 1 2`, `FULL SEND 1 2 --manual-merge`,
# `FULL SEND 1 --manual-merge 2`) — bare integers are issue numbers and
# remain in $@.
NEW_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-permissions) SKIP_PERMS="--dangerously-skip-permissions"; shift ;;
    --skill)            SKILL_FLAG="--skill $2"; shift 2 ;;
    --manual-merge)     MANUAL_MERGE_FLAG="--manual-merge"; shift ;;
    *)                  NEW_ARGS+=("$1"); shift ;;
  esac
done
set -- "${NEW_ARGS[@]}"

MAX_CONCURRENT="${MAX_AGENTS:-3}"
POLL_INTERVAL="${POLL_SECONDS:-60}"
# Number of consecutive low-CPU polls before the runner emits a latched
# `EVENT: agent-stalled` line for a worker (issue #437). Observe-only — the
# runner takes no kill action.
PIPELINE_STALL_POLL_THRESHOLD="${PIPELINE_STALL_POLL_THRESHOLD:-5}"
# Subtree-aggregate CPU at or below this percentage counts as idle and bumps the
# consecutive-idle-polls counter (issue #464). Strict zero missed the #456 wedge
# where the parent claude drained a stuck subprocess's pipe at ~2% CPU. Set to 0
# to restore the old strict-zero semantics. Multi-sampling
# (`PIPELINE_STALL_SAMPLES_PER_POLL`, default 3) takes the max subtree-CPU across
# samples within a poll before comparing — see issue #592.
PIPELINE_STALL_CPU_THRESHOLD="${PIPELINE_STALL_CPU_THRESHOLD:-5}"
# Number of process-table snapshots to take per poll. Multi-sampling smooths
# over short-lived bash children spawned by claude tool calls — `ps` reports
# lifetime-average %cpu, so a single instant snapshot routinely undercounts a
# busy-but-bursty subtree (issue #592). The per-poll CPU reading fed into the
# latch is the MAX across all samples. Set to 1 to restore single-sample
# semantics. Each additional sample adds `PIPELINE_STALL_SAMPLE_INTERVAL_SEC`
# seconds of wall-clock latency to the poll loop.
PIPELINE_STALL_SAMPLES_PER_POLL="${PIPELINE_STALL_SAMPLES_PER_POLL:-3}"
PIPELINE_STALL_SAMPLE_INTERVAL_SEC="${PIPELINE_STALL_SAMPLE_INTERVAL_SEC:-1}"
# Forward-progress gate (issue #641). When enabled (default), a low-CPU poll
# only advances the stall counter if the worker's tmux pane fingerprint is ALSO
# unchanged since the prior poll — a healthy API-bound agent (executor/evaluator
# blocked on the model) idles near 2% CPU but keeps emitting pane output, so CPU
# alone false-flagged it as stalled. Set to 0 to restore pre-#641 CPU-only
# behavior (counter advances on idle CPU regardless of pane progress).
PIPELINE_STALL_FORWARD_PROGRESS_GATE="${PIPELINE_STALL_FORWARD_PROGRESS_GATE:-1}"
# Number of consecutive polls a worker must be observed at the `pr-open` label
# (PR opened, terminal action taken) while still alive before the runner reaps
# it (issue #636). Mirrors PIPELINE_STALL_POLL_THRESHOLD's grace-window shape.
# FAIL-CLOSED: a transient gh error makes executor_finished_terminal() return 1,
# which resets the counter — the runner never reaps mid-`gh pr create`/push. At
# the default 60s poll this is a few-minute grace window. Set higher to widen it.
PIPELINE_EXECUTOR_REAP_GRACE_POLLS="${PIPELINE_EXECUTOR_REAP_GRACE_POLLS:-3}"
STATUS_INTERVAL="${STATUS_INTERVAL:-3}"
REPO_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
: "${CLAUDE_PLUGIN_ROOT:?ERROR: CLAUDE_PLUGIN_ROOT unset; cannot resolve sibling scripts (spawn-claude.sh, queue-status.sh)}"
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_logging.sh"
LOG_DIR="${REPO_ROOT}/.claude/logs"
QUEUE_LOG="${LOG_DIR}/queue-$(date +%Y%m%d-%H%M%S).log"
PENDING_FILE="${LOG_DIR}/queue-pending.txt"

if pipeline_logging_enabled; then
  mkdir -p "$LOG_DIR"
  : > "$QUEUE_LOG"
  : > "$PENDING_FILE"
fi

# Log to stdout, and tee to the queue log only when observability is enabled.
# stdout progress is always preserved so operators see queue activity.
log() {
  if pipeline_logging_enabled; then
    echo "$@" | tee -a "$QUEUE_LOG"
  else
    echo "$@"
  fi
}

# Issue #630: the poll loop (below) makes many external calls per iteration
# (gh, tmux list-panes/list-windows, ps). Under `set -e` a single transient
# non-zero (a gh rate-limit blip, or a tmux race when a window closes between
# snapshots) silently terminates the whole runner with no diagnostic, leaving
# the spawned agents orphaned and the orchestrator without live EVENT lines.
# Two-part fix: (1) an EXIT trap that surfaces an abnormal death with the
# failing command + exit code (so the silent exit-1 becomes diagnosable), and
# (2) `set +e` scoping errexit OFF for the poll-loop region only (see below) so
# a blip degrades a single poll instead of aborting the run. RUNNER_DONE is
# flipped to 1 once the loop exits normally (and before the benign empty-queue
# usage exit), making the trap a no-op on those expected/intended exit paths.
RUNNER_DONE=0
_runner_exit_trap() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$RUNNER_DONE" -eq 0 ]; then
    log "EVENT: runner-aborted cmd=<${BASH_COMMAND}> rc=${rc} line=${BASH_LINENO[0]:-?}"
  fi
}
trap _runner_exit_trap EXIT

# Collect issue queue from args
QUEUE=("$@")
if [ ${#QUEUE[@]} -eq 0 ]; then
  echo "Usage: bash $0 [--skip-permissions] <issue1> <issue2> ..."
  # Issue #630: benign usage exit — silence the abnormal-exit trap.
  RUNNER_DONE=1
  exit 1
fi

# Verify we're inside tmux
if [ -z "${TMUX:-}" ]; then
  echo "ERROR: Must be run inside a tmux session."
  echo "  Start one with: tmux new -s ${PIPELINE_TMUX_SESSION:-dev}"
  exit 1
fi

# Resolve an issue number to its linked PR number, or empty if none exists.
# Exact-scope lookup (issue #518): the prior `linked:<N>` search qualifier was
# NOT exact-scope and returned unrelated PRs that merely mentioned the issue,
# which propagated the wrong PR diff into the pre-spawn classifier (causing
# spurious container-mode dispatch — see issue body). The replacement queries
# candidate PRs with `<N> in:title,body type:pr is:open`, then filters in
# Python to the first PR whose body matches the closing-keyword regex
# `(Close[sd]?|Fix(es|ed)?|Resolve[sd]?) #<N>(?!\d)` (case-insensitive,
# word-boundary anchored — so `#5170` does not match `#517`). Fails closed
# (empty string) on any gh error, malformed payload, or zero match — callers
# already treat empty as "no PR yet", which is the correct semantics when
# the only PR found is unrelated noise. Shared between classify_issue and
# evaluator_finished_terminal so the fix lands once for both call sites.
# Defined BEFORE classify_issue so the single-issue short-circuit (which
# exits before later function definitions execute) sees it at call time.
resolve_issue_pr() {
  local issue="$1"
  local payload
  payload=$(gh pr list --repo "$PIPELINE_REPO" \
    --search "${issue} in:title,body type:pr is:open" \
    --json number,body 2>/dev/null) || return 0
  [ -n "$payload" ] || return 0
  printf '%s' "$payload" | ISSUE="$issue" python3 -c '
import json, os, re, sys
issue = os.environ["ISSUE"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
pat = re.compile(
    r"(?i)(?<![A-Za-z0-9])(Close[sd]?|Fix(?:es|ed)?|Resolve[sd]?) #" +
    re.escape(issue) + r"(?!\d)"
)
for pr in data:
    if pat.search(pr.get("body") or ""):
        print(pr.get("number", ""))
        sys.exit(0)
' 2>/dev/null || return 0
}

# --- Dispatch routing (issue #514) ---
#
# Container isolation and the pre-spawn classifier re-run were removed in
# #514. classify_issue now unconditionally emits mode=bare so the call sites
# in route_issue() and the single-issue short-circuit continue to work
# without re-shaping the four-line tuple they consume. No gh round-trip, no
# mode tokens, no extras — every issue lands in the bare bucket.
classify_issue() {
  printf '%s\n' "bare" "" "0" ""
}

# bucket_max <mode> -> echoes the configured max concurrency for that mode.
# Post-#514 the only bucket is `bare` (global MAX_CONCURRENT cap); the mode
# parameter is retained for call-site stability but no longer affects routing.
bucket_max() {
  echo "$MAX_CONCURRENT"
}

# Single issue — launch directly, no queue overhead
if [ ${#QUEUE[@]} -eq 1 ]; then
  ISSUE="${QUEUE[0]}"
  # Accept BOTH bare `wt-<N>` and slugged `wt-<N>-<slug>` basenames (sibling
  # of #365's cleanup-worktree.sh fix). The basename predicate avoids
  # substring collisions: issue 4 must not match wt-42, 42 must not match wt-481.
  WT_PATH=$(git worktree list --porcelain \
    | awk -v p="${PIPELINE_WORKTREE_PREFIX}-${ISSUE}" \
        '/^worktree / {
           base = $2
           sub(/.*\//, "", base)
           if (base == p || base ~ "^"p"-") { print $2; exit }
         }')
  if [ -z "$WT_PATH" ] || [ ! -d "$WT_PATH" ]; then
    log "ERROR: No worktree found for issue #${ISSUE}."
    exit 1
  fi
  # Tighten the sed so bare `wt-<N>` yields empty (-n + p prints only on
  # match), then fall back to `issue-<N>` so the launched agent never sees
  # a literal `wt-<N>` slug value.
  SLUG=$(basename "$WT_PATH" | sed -n "s/^${PIPELINE_WORKTREE_PREFIX}-[0-9][0-9]*-\(.*\)/\1/p")
  SLUG="${SLUG:-issue-${ISSUE}}"
  log "Single issue — launching directly (no queue)."
  if pipeline_logging_enabled; then
    log "Queue log: ${QUEUE_LOG}"
  fi

  # Issue #514: all dispatches are always-inline / bare; no classifier re-run,
  # no mode tokenization.
  if [ "${PIPELINE_QUEUE_DRY_RUN:-}" = "1" ]; then
    SINGLE_MAX=$(bucket_max "bare")
    echo "BUCKET: mode=bare issues=${ISSUE} max=${SINGLE_MAX}"
  fi
  bash "${SCRIPT_DIR}/spawn-claude.sh" $SKIP_PERMS $SKILL_FLAG $MANUAL_MERGE_FLAG "$WT_PATH" "$ISSUE" "$SLUG" tmux
  exit 0
fi

# Track active and completed issues
declare -A ACTIVE=()    # issue -> worktree path
declare -A RESULTS=()   # issue -> status (running/done/failed)
declare -A LAST_ACTIVITY=()  # issue -> last tmux window activity epoch
# Stall detection (issue #437): count consecutive low-CPU polls per issue and
# latch a single agent-stalled emission per stall window so a wedged worker
# logs once, not every poll. Cleared when the agent recovers or exits.
declare -A CPU_IDLE_POLLS=()  # issue -> consecutive low-CPU poll count
declare -A STALL_LATCHED=()   # issue -> 1 once agent-stalled emitted this window
declare -A PANE_FINGERPRINT=()  # issue -> last-seen tmux-pane fingerprint (forward-progress baseline, #641)
declare -A PR_OPEN_POLLS=()   # issue -> consecutive polls observed at pr-open while alive (issue #636)
QUEUE_INDEX=0
IDLE_TIMEOUT="${IDLE_TIMEOUT:-300}"  # 5 minutes default
POLL_COUNT=0

# --- Bucket state (issue #218) ---
# Per-mode partitioning of the queue. The classifier output for each issue
# routes it into BUCKET_QUEUE[$mode]; fill_slots respects per-mode caps from
# BUCKET_MAX[$mode]. Classifier failures populate SKIPPED so the issue is
# logged but not dispatched. ISSUE_MODE/ISSUE_EXTRAS retain per-issue state
# so finished agents can decrement the right bucket counter.
declare -A BUCKET_QUEUE=()   # mode -> space-separated issue list
declare -A BUCKET_INDEX=()   # mode -> next-issue index in BUCKET_QUEUE
declare -A BUCKET_MAX=()     # mode -> max concurrent for this bucket
declare -A BUCKET_ACTIVE=()  # mode -> currently-active count
declare -A ISSUE_MODE=()     # issue -> mode (always 'bare' post-#514)
declare -A ISSUE_EXTRAS=()   # issue -> retained for call-site stability (unused)

# Route a single issue into the correct bucket. Returns 0 on success, 1 if
# the classifier rejected the issue (in which case a SKIPPED log line is
# emitted and the issue is recorded in RESULTS as 'skipped-by-classifier').
route_issue() {
  local issue="$1"
  local mode extras rc err
  { read -r mode; read -r extras; read -r rc; read -r err; } < <(classify_issue "$issue")
  if [ "$rc" -ne 0 ]; then
    log "SKIPPED issue=${issue} reason=${err}"
    log "EVENT: agent-skipped issue=${issue} reason=${err}"
    RESULTS[$issue]="skipped-by-classifier"
    return 1
  fi
  ISSUE_MODE[$issue]="$mode"
  ISSUE_EXTRAS[$issue]="$extras"
  BUCKET_QUEUE[$mode]="${BUCKET_QUEUE[$mode]:+${BUCKET_QUEUE[$mode]} }${issue}"
  if [ -z "${BUCKET_MAX[$mode]:-}" ]; then
    BUCKET_MAX[$mode]=$(bucket_max "$mode")
    BUCKET_INDEX[$mode]=0
    BUCKET_ACTIVE[$mode]=0
  fi
  return 0
}

STATUS_INTERVAL_SECS=$((STATUS_INTERVAL * POLL_INTERVAL))
log "========================================"
log "AGENT QUEUE RUNNER"
log "========================================"
log "  Issues: ${QUEUE[*]}"
log "  Max concurrent: ${MAX_CONCURRENT}"
log "  Poll interval: ${POLL_INTERVAL}s"
log "  Status interval: every ${STATUS_INTERVAL} polls (${STATUS_INTERVAL_SECS}s)"
log "  Skill: ${SKILL_FLAG:-execute-issue-plan (default)}"
log "  Skip permissions: $([ -n "$SKIP_PERMS" ] && echo 'yes' || echo 'no')"
if pipeline_logging_enabled; then
  log "  Queue log: ${QUEUE_LOG}"
fi
log "  Pending file: ${PENDING_FILE} (append issue numbers here to add mid-run)"
log "========================================"
log ""

# Find worktree path for an issue number.
# Accepts BOTH bare `wt-<N>` and slugged `wt-<N>-<slug>` basenames
# (sibling of #365's cleanup-worktree.sh fix). The basename predicate
# blocks substring collisions: issue 4 != wt-42, issue 42 != wt-481.
find_worktree() {
  local issue="$1"
  local wt_path
  wt_path=$(git worktree list --porcelain \
    | awk -v p="${PIPELINE_WORKTREE_PREFIX}-${issue}" \
        '/^worktree / {
           base = $2
           sub(/.*\//, "", base)
           if (base == p || base ~ "^"p"-") { print $2; exit }
         }')
  echo "$wt_path"
}

# Extract slug from worktree path (e.g., ct-66-rating-consistency -> rating-consistency).
# Bare `wt-<N>` basenames have no slug component; the `-n + p` sed prints
# only on match, yielding an empty string that the caller falls back from.
slug_from_path() {
  local path="$1"
  local issue="${2:-}"
  local slug
  slug=$(basename "$path" | sed -n "s/^${PIPELINE_WORKTREE_PREFIX}-[0-9][0-9]*-\(.*\)/\1/p")
  echo "${slug:-issue-${issue}}"
}

# Check if an agent's tmux window is still alive
is_agent_running() {
  local issue="$1"
  tmux list-windows -t "${PIPELINE_TMUX_SESSION:-dev}" -F '#{window_name}' 2>/dev/null | grep -q "^issue-${issue}$"
}

# Reap a finished/wedged worker: kill its process GROUP (the
# script->timeout->claude tree rooted at the tmux pane pid) before closing the
# window, so `queue-complete` implies no orphaned child survives the reap (issue
# #666). Bare `tmux kill-window` only tears down the pane's controlling terminal;
# the spawned claude can survive detached, holding the worktree + a slot.
# Fail-safe: any missing pane pid / pgid simply skips the kill and still closes
# the window, so a transient tmux/ps blip never errors the runner under the
# poll-loop's `set +e` region.
reap_worker_window() {
  local issue="$1"
  local pane_pid pgid
  pane_pid=$(tmux list-panes -t "${PIPELINE_TMUX_SESSION:-dev}:issue-${issue}" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -n "$pane_pid" ]; then
    pgid=$(ps -o pgid= -p "$pane_pid" 2>/dev/null | tr -d ' ')
    if [ -n "$pgid" ]; then
      kill -TERM "-${pgid}" 2>/dev/null || true
      sleep "${PIPELINE_REAP_SIGKILL_GRACE_SEC:-2}"
      kill -KILL "-${pgid}" 2>/dev/null || true
    fi
  fi
  tmux kill-window -t "${PIPELINE_TMUX_SESSION:-dev}:issue-${issue}" 2>/dev/null || true
}

# Echo the %CPU of an agent's tmux pane process subtree (issue #437). Resolves
# the pane pid from the issue's window, then sums `%cpu` across pane_pid and all
# its descendants from a caller-supplied snapshot of the process table. Per-
# process reads of pane_pid would miss the real work: spawn-claude.sh launches
# agents as `[script→]timeout→claude`, and `timeout` blocks in `wait()` at ~0%
# CPU, so a pane_pid-only read flags every healthy worker as stalled in the
# logging-off path. Echoes 0.0 on any lookup failure so the stall counter
# advances rather than masking a wedge. The caller latches on this aggregate
# being <= PIPELINE_STALL_CPU_THRESHOLD (no longer strict zero, issue #464), so
# a healthy worker must keep the subtree above that threshold to avoid the
# stall counter advancing.
#
# Args: $1=issue, $2=process snapshot (output of `ps -eo pid=,ppid=,%cpu=`).
# The caller captures PIPELINE_STALL_SAMPLES_PER_POLL snapshots per poll
# (issue #592) and feeds each one through this function, taking the MAX
# subtree-CPU across samples before comparing against the threshold. This
# function itself is unchanged — it still scopes the subtree from a single
# snapshot.
get_agent_cpu_pct() {
  local issue="$1"
  local snapshot="$2"
  local pane_pid
  pane_pid=$(tmux list-panes -t "${PIPELINE_TMUX_SESSION:-dev}:issue-${issue}" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -z "$pane_pid" ] || [ -z "$snapshot" ]; then
    echo "0.0"
    return
  fi
  echo "$snapshot" | awk -v root="$pane_pid" '
    {
      cpu[$1] = $3
      if (kids[$2]) kids[$2] = kids[$2] " " $1
      else          kids[$2] = $1
    }
    END {
      qh = 0; qt = 0
      queue[qt++] = root
      total = 0.0
      while (qh < qt) {
        cur = queue[qh++]
        if (visited[cur]++) continue
        if (cpu[cur] != "") total += cpu[cur]
        if (kids[cur]) {
          n = split(kids[cur], children, " ")
          for (i = 1; i <= n; i++) queue[qt++] = children[i]
        }
      }
      printf "%.1f", total
    }
  '
}

# Forward-progress probe (issue #641). Echoes a fingerprint of the worker's
# tmux pane: "<bytes>:<cksum>" of `capture-pane -p`. A changing fingerprint
# poll-over-poll == the worker is still emitting (assistant tokens / tool
# output) == forward progress, even while subtree CPU sits at the ~2% an
# API-bound LLM agent idles at. A frozen fingerprint across the stall window
# == a genuine wedge. Uses only the runner's native tmux addressing
# (session:issue-N) and POSIX cksum -- NO session-uuid / .jsonl / runs.log
# handle (the runner has none) and NO PIPELINE_LOGS_ENABLED dependency, so it
# works identically on consumer hosts. On any tmux failure echoes the
# sentinel "0:0" -- a capture failure reads as "no progress observed" so it
# CANNOT mask a wedge (fail-closed toward latching; mirrors get_agent_cpu_pct
# echoing 0.0 to advance the counter rather than hide a stall).
get_agent_pane_fingerprint() {
  local issue="$1"
  local cap
  cap=$(tmux capture-pane -t "${PIPELINE_TMUX_SESSION:-dev}:issue-${issue}" -p 2>/dev/null) || cap=""
  if [ -z "$cap" ]; then echo "0:0"; return; fi
  printf '%s' "$cap" | cksum | awk '{printf "%s:%s", $2, $1}'
}

# Launch an agent for an issue. Threads classifier-derived flags (mode +
# passthrough tokens) into the spawn-claude invocation.
launch_agent() {
  local issue="$1"
  local wt_path
  wt_path=$(find_worktree "$issue")

  if [ -z "$wt_path" ] || [ ! -d "$wt_path" ]; then
    log "[$(date +%H:%M:%S)] ERROR: No worktree found for issue #${issue}. Skipping."
    RESULTS[$issue]="failed-no-worktree"
    return 1
  fi

  local slug
  slug=$(slug_from_path "$wt_path" "$issue")

  # Issue #514: every dispatch is always-inline / bare. No mode token, no
  # inline browser-eval EVENT short-circuit, no per-mode bucket counter —
  # the orchestrator owns inline browser-eval dispatch downstream.
  local mode="bare"

  log "[$(date +%H:%M:%S)] [$(date +%s)] Launching agent for issue #${issue} (${slug}, mode=${mode})..."
  log "EVENT: agent-launched issue=${issue} mode=${mode} slug=${slug} worktree=${wt_path}"

  bash "${SCRIPT_DIR}/spawn-claude.sh" $SKIP_PERMS $SKILL_FLAG $MANUAL_MERGE_FLAG "$wt_path" "$issue" "$slug" tmux

  ACTIVE[$issue]="$wt_path"
  RESULTS[$issue]="running"
  BUCKET_ACTIVE[$mode]=$(( ${BUCKET_ACTIVE[$mode]:-0} + 1 ))
}

# Check GitHub for issue outcome (PR created? merged?)
check_issue_outcome() {
  local issue="$1"
  local labels
  labels=$(gh issue view "$issue" --repo "$PIPELINE_REPO" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

  if echo "$labels" | grep -q "merged"; then
    echo "merged"
  elif echo "$labels" | grep -q "pr-open"; then
    echo "pr-open"
  elif echo "$labels" | grep -q "in-progress"; then
    echo "in-progress"
  else
    echo "unknown"
  fi
}

# resolve_issue_pr is defined earlier in this file (before classify_issue) so
# that single-issue short-circuit invocations — which exit before reaching
# this point in the script — still see its definition at function-call time
# (bash registers function definitions at execution time, not parse time).

# Detect evaluator sessions that have completed their work but whose claude
# child has not exited (manual-merge / block-* branch — issue #489). The
# tmux-window-presence check in is_agent_running() is necessary but not
# sufficient: when the evaluator skips Step 11 auto-merge (verdict recommends
# manual merge, or any block-* reason fires), the spawned `claude -p` process
# can sit indefinitely until the per-agent timeout fires, never closing its
# tmux window. This predicate gives the runner a second terminal signal sourced
# from GitHub state.
#
# Returns 0 (terminal) iff EITHER:
#   (a) the issue carries the `manual-merge` label (the evaluator auto-applies
#       this on every block-* skip per skills/evaluate-issue-pr/SKILL.md Step
#       11.4; before that change rolls out, only operator-pre-labelled issues
#       match this arm), OR
#   (b) the issue's linked PR's latest comment body starts with
#       `Auto-merge skipped:` (the block-* fallback shape from
#       skills/evaluate-issue-pr/SKILL.md) AND the latest `## Evaluation` PR
#       comment contains `**Verdict:** Approved`.
# Returns 1 otherwise. Fails closed: any gh error, empty PR lookup, or missing
# `## Evaluation` payload returns 1 so a transient API blip cannot prematurely
# terminate a healthy worker.

# Recover the gate's actual block-reason for a wedged evaluator's PR. The
# evaluator posts `Auto-merge skipped: <REASON>. Run gh pr merge manually.`
# for ANY block-* skip (skills/evaluate-issue-pr/SKILL.md Step 11.4), where
# <REASON> is one of the auto-merge-gate.sh tokens (block-verdict, block-ci,
# block-mergeable, block-mergestate, block-label, block-flag,
# block-base-mismatch). Scan ALL PR comments (the skipped line is not always
# the last comment under the manual-merge label arm). Fail-soft: prints
# `unknown` on any gh error / no PR / no skipped line so the emit never breaks.
extract_block_reason() {
  local issue="$1" pr reason
  pr=$(resolve_issue_pr "$issue")
  [ -n "$pr" ] && [ "$pr" != "null" ] || { echo unknown; return 0; }
  reason=$(gh pr view "$pr" --repo "$PIPELINE_REPO" --json comments \
    --jq '.comments[].body' 2>/dev/null \
    | grep -oE 'Auto-merge skipped: (block-[a-z-]+|green)' \
    | head -1 | awk '{print $NF}')
  [ -n "$reason" ] && echo "$reason" || echo unknown
}
evaluator_finished_terminal() {
  local issue="$1"
  local labels
  labels=$(gh issue view "$issue" --repo "$PIPELINE_REPO" \
    --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 1
  # Both arms require a linked PR. Bail if no PR yet (executor crashed pre-PR —
  # must NOT kill the worker). `gh ... --jq '.[0].number'` prints the literal
  # string `null` for an empty result set (not an empty string), so guard
  # against both before querying the PR.
  local pr
  pr=$(resolve_issue_pr "$issue")
  [ -n "$pr" ] && [ "$pr" != "null" ] || return 1
  # Both arms require a `## Evaluation` comment on the linked PR as
  # proof-of-completion. Without this guard the label arm fires on any
  # pre-applied `manual-merge` label (operator opt-out OR a residual label
  # from a prior block-* skip that cleanup-worktree.sh never removes),
  # killing a still-running worker on poll 1.
  local eval_body
  eval_body=$(gh pr view "$pr" --repo "$PIPELINE_REPO" \
    --json comments \
    --jq '[.comments[] | select(.body | contains("## Evaluation"))] | last | .body' \
    2>/dev/null) || return 1
  [ -n "$eval_body" ] || return 1
  # Arm (a): manual-merge label present AND evaluation comment exists.
  # Comma-anchored so a hypothetical `not-manual-merge` label cannot match.
  if echo ",$labels," | grep -q ',manual-merge,'; then
    return 0
  fi
  # Arm (b): Auto-merge skipped PR-comment fallback + Approved verdict.
  local last_pr_comment
  last_pr_comment=$(gh pr view "$pr" --repo "$PIPELINE_REPO" \
    --json comments --jq '.comments[-1].body' 2>/dev/null) || return 1
  echo "$last_pr_comment" | grep -q '^Auto-merge skipped:' || return 1
  echo "$eval_body" | grep -q '\*\*Verdict:\*\* Approved' || return 1
  return 0
}

# Detect an executor session that has opened its PR (issue at `pr-open`) but
# whose spawned claude child has not exited — the post-PR lingering wedge
# (issue #636). Symmetric to evaluator_finished_terminal(): the
# is_agent_running() window-presence check is necessary but not sufficient,
# because the executor can sit idle holding the worktree + a concurrency slot
# until the per-agent timeout fires. This predicate gives the runner a second
# terminal signal sourced from GitHub state.
#
# Returns 0 (terminal) iff the issue carries the `pr-open` label (the terminal
# action — PR opened — has already been taken) AND is NOT yet `merged`. The
# caller gates the actual reap behind a grace window (PR_OPEN_POLLS >=
# PIPELINE_EXECUTOR_REAP_GRACE_POLLS) so a worker mid-`gh pr create`/push is
# never killed. Fails closed: any gh error, empty labels, missing `pr-open`,
# or a `merged` label returns 1 (the merged/auto-merge case is owned by the
# existing is_agent_running / check_issue_outcome branches).
executor_finished_terminal() {
  local issue="$1"
  local labels
  labels=$(gh issue view "$issue" --repo "$PIPELINE_REPO" \
    --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 1
  [ -n "$labels" ] || return 1
  # merged supersedes pr-open: the evaluator/auto-merge already advanced the
  # issue; let the existing branches reap it. Comma-anchored exact match.
  echo ",$labels," | grep -q ',merged,' && return 1
  # Require pr-open present (terminal action taken). Comma-anchored so a
  # hypothetical `not-pr-open` label cannot match.
  echo ",$labels," | grep -q ',pr-open,' || return 1
  return 0
}

# Check if the pending file has at least one non-empty line
pending_file_has_items() {
  [ -f "$PENDING_FILE" ] || return 1
  grep -q '[^[:space:]]' "$PENDING_FILE" 2>/dev/null
}

# Atomically drain the pending file and add new issues to the queue.
# Each new issue is classified and routed into the appropriate bucket.
drain_pending_file() {
  [ -f "$PENDING_FILE" ] || return 0
  # Atomically move to a temp file on the same filesystem
  local tmp
  tmp=$(mktemp "${LOG_DIR}/queue-drain-XXXXXX")
  mv "$PENDING_FILE" "$tmp"
  while IFS= read -r line; do
    line=$(echo "$line" | tr -d '[:space:]')
    [ -z "$line" ] && continue
    if [[ "${RESULTS[$line]+_}" ]]; then
      log "[$(date +%H:%M:%S)] WARN: Issue #${line} already in queue — skipping duplicate."
      continue
    fi
    log "[$(date +%H:%M:%S)] Picked up new issue #${line} from pending file."
    QUEUE+=("$line")
    RESULTS[$line]=""  # mark as known
    route_issue "$line" || true
  done < "$tmp"
  rm -f "$tmp"
}

# Fill available slots from per-bucket queues, respecting each bucket's cap.
fill_slots() {
  local mode
  for mode in "${!BUCKET_QUEUE[@]}"; do
    local -a bq
    # shellcheck disable=SC2206
    bq=( ${BUCKET_QUEUE[$mode]} )
    while [ "${BUCKET_ACTIVE[$mode]:-0}" -lt "${BUCKET_MAX[$mode]:-1}" ] \
          && [ "${BUCKET_INDEX[$mode]:-0}" -lt "${#bq[@]}" ]; do
      local idx="${BUCKET_INDEX[$mode]:-0}"
      local next_issue="${bq[$idx]}"
      BUCKET_INDEX[$mode]=$((idx + 1))
      launch_agent "$next_issue" || true
    done
  done
}

# Classify the initial queue and partition into per-mode buckets.
for _issue in "${QUEUE[@]}"; do
  RESULTS[$_issue]=""
  route_issue "$_issue" || true
done

# Dry-run hook: short-circuit after initial classification + first fill,
# emitting one `BUCKET: mode=... issues=... max=N` line per bucket so tests
# can assert partitioning + concurrency caps without entering the poll loop.
if [ "${PIPELINE_QUEUE_DRY_RUN:-}" = "1" ]; then
  for _m in "${!BUCKET_QUEUE[@]}"; do
    _list=$(echo "${BUCKET_QUEUE[$_m]}" | tr ' ' ',')
    echo "BUCKET: mode=${_m} issues=${_list} max=${BUCKET_MAX[$_m]}"
  done
  fill_slots
  exit 0
fi

# Initial launch
fill_slots

log ""
log "[$(date +%H:%M:%S)] Monitoring... (polling every ${POLL_INTERVAL}s)"
log ""

# True iff any bucket still has un-launched issues queued.
buckets_have_pending() {
  local m bq_count
  for m in "${!BUCKET_QUEUE[@]}"; do
    bq_count=$(echo "${BUCKET_QUEUE[$m]}" | wc -w)
    if [ "${BUCKET_INDEX[$m]:-0}" -lt "$bq_count" ]; then
      return 0
    fi
  done
  return 1
}

# Issue #630: errexit OFF for the poll-loop region. Each iteration runs many
# external commands whose transient non-zero must degrade THAT poll, not kill
# the runner. `set -u`/`pipefail` stay in force (only `-e` is the footgun here).
set +e

# Poll loop — continues while agents are active, items are queued, or pending file has items
while [ ${#ACTIVE[@]} -gt 0 ] || buckets_have_pending || pending_file_has_items; do
  sleep "$POLL_INTERVAL"
  POLL_COUNT=$((POLL_COUNT + 1))

  # Pick up any dynamically added issues
  drain_pending_file
  fill_slots

  # Multi-sample process-table snapshots per poll (issue #592). `ps` reports
  # lifetime-average %cpu, so a single instant snapshot routinely undercounts
  # short-lived bash children spawned by claude tool calls. Take
  # PIPELINE_STALL_SAMPLES_PER_POLL snapshots ~1s apart and feed each through
  # the per-agent subtree summer; the caller's reading is the max across
  # samples. Snapshots are shared across all active agents so we still avoid
  # 2N ps forks (issue #437).
  PS_SNAPSHOTS=()
  for _ in $(seq 1 "$PIPELINE_STALL_SAMPLES_PER_POLL"); do
    PS_SNAPSHOTS+=("$(ps -eo pid=,ppid=,%cpu= 2>/dev/null || echo "")")
    [ "$PIPELINE_STALL_SAMPLES_PER_POLL" -gt 1 ] && sleep "$PIPELINE_STALL_SAMPLE_INTERVAL_SEC"
  done

  # Check each active agent
  for issue in "${!ACTIVE[@]}"; do
    # Stall detection (issue #437): track consecutive low-CPU polls (subtree
    # aggregate <= PIPELINE_STALL_CPU_THRESHOLD) and emit a single latched EVENT
    # line per stall window. Observe-only — no kill. The CPU reading is the
    # max subtree-aggregate across PIPELINE_STALL_SAMPLES_PER_POLL snapshots
    # (issue #592) so bursty workers (claude tool-calls spinning short-lived
    # bash children) don't get falsely flagged.
    cpu="0.0"
    for _snap in "${PS_SNAPSHOTS[@]}"; do
      _s=$(get_agent_cpu_pct "$issue" "$_snap")
      _s_int=${_s%%.*}; _s_int=${_s_int:-0}
      _c_int=${cpu%%.*}; _c_int=${_c_int:-0}
      case "$_s_int" in ''|*[!0-9]*) _s_int=0 ;; esac
      case "$_c_int" in ''|*[!0-9]*) _c_int=0 ;; esac
      if [ "$_s_int" -gt "$_c_int" ]; then cpu="$_s"; fi
    done
    cpu_int=${cpu%%.*}; cpu_int=${cpu_int:-0}
    # Digit-guard: if ps returned junk, coerce to 0 so the `-le` test below
    # never errors on a non-numeric operand (which would abort the runner).
    case "$cpu_int" in
      ''|*[!0-9]*) cpu_int=0 ;;
    esac
    if [ "$cpu_int" -le "$PIPELINE_STALL_CPU_THRESHOLD" ]; then
      # CPU pre-filter says "maybe idle". Before advancing the stall counter,
      # require NO forward progress (issue #641): compare the pane fingerprint to
      # last poll's. A healthy API-bound worker idles near 2% CPU but keeps
      # emitting pane output, so CPU alone false-flagged it.
      progressed=0
      if [ "${PIPELINE_STALL_FORWARD_PROGRESS_GATE:-1}" != "0" ]; then
        fp=$(get_agent_pane_fingerprint "$issue")
        prev_fp="${PANE_FINGERPRINT[$issue]:-}"
        PANE_FINGERPRINT[$issue]="$fp"
        # First idle poll has no baseline (prev empty) -> treat as progressed so
        # we don't latch on the very first low-CPU sample; a real wedge stays
        # frozen and latches on subsequent polls.
        if [ -z "$prev_fp" ] || [ "$fp" != "$prev_fp" ]; then progressed=1; fi
      fi
      if [ "$progressed" -eq 1 ]; then
        # Forward progress at idle CPU == healthy API-bound worker. Reset.
        CPU_IDLE_POLLS[$issue]=0
        STALL_LATCHED[$issue]=0
      else
        CPU_IDLE_POLLS[$issue]=$(( ${CPU_IDLE_POLLS[$issue]:-0} + 1 ))
        if [ "${CPU_IDLE_POLLS[$issue]}" -ge "$PIPELINE_STALL_POLL_THRESHOLD" ] \
           && [ "${STALL_LATCHED[$issue]:-0}" -eq 0 ]; then
          pid=$(tmux list-panes -t "${PIPELINE_TMUX_SESSION:-dev}:issue-${issue}" -F '#{pane_pid}' 2>/dev/null | head -1)
          window="issue-${issue}"
          elapsed=$(( CPU_IDLE_POLLS[$issue] * POLL_INTERVAL / 60 ))
          log "EVENT: agent-stalled issue=${issue} pid=${pid:-?} window=${window} elapsed=${elapsed}m"
          STALL_LATCHED[$issue]=1
        fi
      fi
    else
      CPU_IDLE_POLLS[$issue]=0
      STALL_LATCHED[$issue]=0
      PANE_FINGERPRINT[$issue]=""   # busy CPU resets the progress baseline (#641)
    fi

    if evaluator_finished_terminal "$issue"; then
      # Manual-merge / block-* branch (issue #489): the evaluator has finished
      # posting its verdict but the spawned claude child is still alive, so the
      # tmux window never closed on its own. Kill the window so the existing
      # finish-branch invariants hold (window absent => slot free), record the
      # specific outcome, free the bucket slot, and fill the gap. Checked BEFORE
      # is_agent_running so this more-specific signal wins when both are true on
      # the same poll.
      reap_worker_window "$issue"
      outcome="manual-merge-required"
      _block_reason=$(extract_block_reason "$issue")
      RESULTS[$issue]="$outcome"
      _finished_mode="${ISSUE_MODE[$issue]:-bare}"
      BUCKET_ACTIVE[$_finished_mode]=$(( ${BUCKET_ACTIVE[$_finished_mode]:-1} - 1 ))
      unset 'ACTIVE['"$issue"']'
      unset 'CPU_IDLE_POLLS['"$issue"']' 'STALL_LATCHED['"$issue"']' 'PANE_FINGERPRINT['"$issue"']'
      log "[$(date +%H:%M:%S)] Agent for issue #${issue} finished — outcome: ${outcome} (reason: ${_block_reason}, evaluator terminal, window force-closed)"
      log "EVENT: agent-finished issue=${issue} outcome=${outcome} reason=${_block_reason} mode=${_finished_mode}"
      fill_slots
      continue
    fi

    if executor_finished_terminal "$issue"; then
      # Executor lingering past pr-open (issue #636): PR opened + pr-open applied,
      # but the spawned claude child has not exited, holding the worktree + slot.
      # Require the pr-open observation to PERSIST across a grace window before
      # reaping so we NEVER kill a worker mid-`gh pr create`/push — a transient gh
      # blip flips the predicate to non-terminal, resetting the counter. Checked
      # AFTER evaluator_finished_terminal so a manual-merge/block wedge (which also
      # carries pr-open) records manual-merge-required, not a bare pr-open.
      PR_OPEN_POLLS[$issue]=$(( ${PR_OPEN_POLLS[$issue]:-0} + 1 ))
      if [ "${PR_OPEN_POLLS[$issue]}" -ge "$PIPELINE_EXECUTOR_REAP_GRACE_POLLS" ]; then
        reap_worker_window "$issue"
        outcome="pr-open"
        RESULTS[$issue]="$outcome"
        _finished_mode="${ISSUE_MODE[$issue]:-bare}"
        BUCKET_ACTIVE[$_finished_mode]=$(( ${BUCKET_ACTIVE[$_finished_mode]:-1} - 1 ))
        unset 'ACTIVE['"$issue"']'
        unset 'CPU_IDLE_POLLS['"$issue"']' 'STALL_LATCHED['"$issue"']' 'PR_OPEN_POLLS['"$issue"']'
        log "[$(date +%H:%M:%S)] Agent for issue #${issue} finished — outcome: ${outcome} (executor terminal, reaped after ${PIPELINE_EXECUTOR_REAP_GRACE_POLLS}-poll grace, window force-closed)"
        log "EVENT: agent-finished issue=${issue} outcome=${outcome} mode=${_finished_mode}"
        fill_slots
        continue
      fi
    else
      # Predicate non-terminal this poll: reset the grace counter so the reap
      # only fires on a CONTIGUOUS pr-open observation window (fail-closed).
      PR_OPEN_POLLS[$issue]=0
    fi

    if ! is_agent_running "$issue"; then
      # Agent finished — check outcome
      outcome=$(check_issue_outcome "$issue")
      RESULTS[$issue]="$outcome"
      _finished_mode="${ISSUE_MODE[$issue]:-bare}"
      BUCKET_ACTIVE[$_finished_mode]=$(( ${BUCKET_ACTIVE[$_finished_mode]:-1} - 1 ))
      unset 'ACTIVE['"$issue"']'
      # Clear stall-tracking state so a re-used issue number can't inherit a
      # stale counter/latch (issue #437) or progress baseline (issue #641).
      unset 'CPU_IDLE_POLLS['"$issue"']' 'STALL_LATCHED['"$issue"']' 'PANE_FINGERPRINT['"$issue"']'
      log "[$(date +%H:%M:%S)] Agent for issue #${issue} finished — outcome: ${outcome}"
      log "EVENT: agent-finished issue=${issue} outcome=${outcome} mode=${_finished_mode}"

      # Fill the open slot
      fill_slots
    fi
  done

  # Periodic rich status or simple status line
  if [ $((POLL_COUNT % STATUS_INTERVAL)) -eq 0 ]; then
    # Capture status output first, then append — avoids simultaneous read/write
    # on $QUEUE_LOG. Non-fatal: status reporting must never kill the queue runner.
    _status_out=$(PIPELINE_PROJECT_ROOT="$REPO_ROOT" bash "${SCRIPT_DIR}/queue-status.sh" --queue-log "$QUEUE_LOG" 2>&1) || true
    if [ -n "$_status_out" ]; then
      echo "$_status_out" | tee -a "$QUEUE_LOG"
    fi
  else
    active_list=""
    for issue in "${!ACTIVE[@]}"; do
      active_list="${active_list}#${issue} "
    done
    remaining=$((${#QUEUE[@]} - QUEUE_INDEX))
    log "[$(date +%H:%M:%S)] Active: ${active_list:-none} | Queued: ${remaining}"
  fi
done

# Issue #630: poll loop exited normally — mark done so the EXIT trap does not
# emit a runner-aborted diagnostic for the intended `queue-complete` exit.
RUNNER_DONE=1

# Final summary
log ""
log "========================================"
log "QUEUE COMPLETE — $(date)"
log "========================================"
log "EVENT: queue-complete total=${#QUEUE[@]}"
printf "%-10s %-15s %s\n" "Issue" "Outcome" "Log" | tee -a "$QUEUE_LOG"
log "----------------------------------------"
for issue in "${QUEUE[@]}"; do
  outcome="${RESULTS[$issue]:-unknown}"
  log_file=$(ls -t "${LOG_DIR}"/issue-"${issue}"-*.log 2>/dev/null | head -1 || echo "n/a")
  printf "%-10s %-15s %s\n" "#${issue}" "$outcome" "$(basename "${log_file}")" | tee -a "$QUEUE_LOG"
done
log "========================================"
log ""
log "Review details: bash \${CLAUDE_PLUGIN_ROOT}/scripts/review-logs.sh"
