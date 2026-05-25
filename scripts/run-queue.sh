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
# to restore the old strict-zero semantics.
PIPELINE_STALL_CPU_THRESHOLD="${PIPELINE_STALL_CPU_THRESHOLD:-5}"
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

# Collect issue queue from args
QUEUE=("$@")
if [ ${#QUEUE[@]} -eq 0 ]; then
  echo "Usage: bash $0 [--skip-permissions] <issue1> <issue2> ..."
  exit 1
fi

# Verify we're inside tmux
if [ -z "${TMUX:-}" ]; then
  echo "ERROR: Must be run inside a tmux session."
  echo "  Start one with: tmux new -s ${PIPELINE_TMUX_SESSION:-dev}"
  exit 1
fi

# --- Pre-spawn classifier (issue #218) ---
#
# classify_issue <issue> resolves the issue's current PR number (or empty
# if no PR has opened yet) and invokes ${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh.
# It echoes a single tab-separated line on stdout:
#   <mode>\t<extra-tokens>\t<rc>\t<stderr-first-line>
# where <mode> is `bare` when no --container-mode token was emitted, or
# the value of the --container-mode=<value> token otherwise. Extra tokens
# (any non-`--container-mode=` tokens from the classifier) are joined by
# spaces. Callers MUST tolerate empty <extra-tokens>. rc != 0 means the
# issue should be skipped; <stderr-first-line> carries the reason.
#
# --ci-fix re-dispatch is intentionally NOT re-classified — recovery is
# mode-agnostic; consumers wanting containerized CI-fix re-label the PR.
classify_issue() {
  local issue="$1"
  # Short-circuit when no classifier is configured — skip the gh pr list call
  # entirely. The helper would still return mode=bare in this case, but the
  # wasted gh round-trip is a real cost at multi-issue slate sizes.
  if [ -z "${PIPELINE_EVAL_CLASSIFIER:-}" ]; then
    printf '%s\n' "bare" "" "0" ""
    return
  fi
  local pr=""
  # `linked:<issue>` is the proven qualifier in this repo for issue->PR lookup
  # (mirrors scripts/check-ci-fix-loop.sh). `head:<prefix>` does NOT work
  # because GitHub search requires an exact branch ref.
  pr=$(gh pr list --repo "$PIPELINE_REPO" --search "linked:${issue}" --json number --jq '.[0].number' 2>/dev/null || echo "")
  local _classifier_invoke="${CLAUDE_PLUGIN_ROOT:-.}/scripts/eval-classifier-invoke.sh"
  local out err rc
  # Fail-OPEN: when the plugin-shipped helper is missing (e.g. a partial
  # upgrade, a stale install, or a worktree without CLAUDE_PLUGIN_ROOT
  # resolution), surface mode=bare with a diagnostic stderr token rather
  # than blocking the entire queue dispatch. Reconciles run-queue.sh with
  # spawn-claude.sh's pre-existing fail-OPEN shape (#325).
  if [ -f "$_classifier_invoke" ]; then
    local tmp_out tmp_err
    tmp_out=$(mktemp); tmp_err=$(mktemp)
    # PIPELINE_EVAL_CLASSIFIER is sourced into this shell but not auto-exported;
    # pass it inline so the child bash sees it. PIPELINE_PROJECT_ROOT anchors
    # consumer-relative classifier paths at the project root rather than the
    # plugin install dir. Use `&& rc=0 || rc=$?` to capture a non-zero exit
    # instead of letting `set -e` kill the function.
    PIPELINE_EVAL_CLASSIFIER="${PIPELINE_EVAL_CLASSIFIER:-}" \
      PIPELINE_PROJECT_ROOT="$REPO_ROOT" \
      PIPELINE_REPO="${PIPELINE_REPO:-}" \
      bash "$_classifier_invoke" "$issue" "$pr" > "$tmp_out" 2> "$tmp_err" \
        && rc=0 || rc=$?
    out=$(cat "$tmp_out"); err=$(head -1 "$tmp_err")
    rm -f "$tmp_out" "$tmp_err"
  else
    printf '%s\n' "bare" "" "0" "classifier-helper-missing: $_classifier_invoke"
    return
  fi

  local mode="bare"
  local extras=""
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in
      --container-mode=*) mode="${tok#--container-mode=}" ;;
      *)                  extras="${extras:+$extras }$tok" ;;
    esac
  done <<< "$out"
  # Emit one field per line so empty `extras` doesn't get collapsed by IFS
  # whitespace-merging on the consumer side.
  printf '%s\n' "$mode" "$extras" "$rc" "$err"
}

# Source the case-insensitive env-var resolver (#336). UPPERCASE wins,
# lowercase falls back. Idempotent guard. Sourced from SCRIPT_DIR (the
# plugin's scripts/ dir), mirroring the _logging.sh source above.
if ! declare -f _resolve_container_var >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/_resolve-container-var.sh"
fi

# bucket_max <mode> -> echoes the configured max concurrency for that mode.
# Default 1 for non-bare modes (exclusive-resource assumption); bare uses
# the global MAX_CONCURRENT.
bucket_max() {
  local mode="$1"
  if [ "$mode" = "bare" ]; then
    echo "$MAX_CONCURRENT"
    return
  fi
  local val
  val="$(_resolve_container_var "$mode" MAX_CONCURRENT)"
  echo "${val:-1}"
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

  # Apply classifier even on the short-circuit path so container mode is honored.
  { read -r SINGLE_MODE; read -r SINGLE_EXTRAS; read -r SINGLE_RC; read -r SINGLE_ERR; } < <(classify_issue "$ISSUE")
  if [ "$SINGLE_RC" -ne 0 ]; then
    log "SKIPPED issue=${ISSUE} reason=${SINGLE_ERR}"
    exit 0
  fi
  SINGLE_FLAGS=""
  if [ "$SINGLE_MODE" != "bare" ]; then
    SINGLE_FLAGS="--container-mode=${SINGLE_MODE}"
  fi
  for tok in $SINGLE_EXTRAS; do
    SINGLE_FLAGS="${SINGLE_FLAGS:+$SINGLE_FLAGS }--classifier-passthrough=${tok}"
  done

  if [ "${PIPELINE_QUEUE_DRY_RUN:-}" = "1" ]; then
    SINGLE_MAX=$(bucket_max "$SINGLE_MODE")
    echo "BUCKET: mode=${SINGLE_MODE} issues=${ISSUE} max=${SINGLE_MAX}"
  fi
  bash "${SCRIPT_DIR}/spawn-claude.sh" $SKIP_PERMS $SKILL_FLAG $MANUAL_MERGE_FLAG $SINGLE_FLAGS "$WT_PATH" "$ISSUE" "$SLUG" tmux
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
declare -A ISSUE_MODE=()     # issue -> mode (or 'bare')
declare -A ISSUE_EXTRAS=()   # issue -> space-separated passthrough tokens

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
# The snapshot is captured once per poll by the caller to avoid 2N ps forks per
# poll over N active agents.
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

  local mode="${ISSUE_MODE[$issue]:-bare}"
  local extras="${ISSUE_EXTRAS[$issue]:-}"
  local mode_flags=""
  if [ "$mode" != "bare" ]; then
    mode_flags="--container-mode=${mode}"
  fi
  for tok in $extras; do
    mode_flags="${mode_flags:+$mode_flags }--classifier-passthrough=${tok}"
  done

  log "[$(date +%H:%M:%S)] [$(date +%s)] Launching agent for issue #${issue} (${slug}, mode=${mode})..."
  log "EVENT: agent-launched issue=${issue} mode=${mode} slug=${slug} worktree=${wt_path}"
  bash "${SCRIPT_DIR}/spawn-claude.sh" $SKIP_PERMS $SKILL_FLAG $MANUAL_MERGE_FLAG $mode_flags "$wt_path" "$issue" "$slug" tmux

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

# Resolve an issue number to its linked PR number, or empty if none exists.
# Mirrors the `linked:<issue>` qualifier used by classify_issue_mode() at the
# top of this file and scripts/check-ci-fix-loop.sh — the only qualifier
# GitHub search reliably honors for issue->PR lookup here. Fails closed (empty
# string) on any gh error so callers can treat "no PR" as "not terminal yet".
resolve_issue_pr() {
  local issue="$1"
  gh pr list --repo "$PIPELINE_REPO" --search "linked:${issue}" \
    --json number --jq '.[0].number' 2>/dev/null || true
}

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

# Poll loop — continues while agents are active, items are queued, or pending file has items
while [ ${#ACTIVE[@]} -gt 0 ] || buckets_have_pending || pending_file_has_items; do
  sleep "$POLL_INTERVAL"
  POLL_COUNT=$((POLL_COUNT + 1))

  # Pick up any dynamically added issues
  drain_pending_file
  fill_slots

  # One process-table snapshot per poll, shared across all active agents (issue
  # #437). Captured here so each call to get_agent_cpu_pct doesn't re-fork ps.
  PS_SNAPSHOT=$(ps -eo pid=,ppid=,%cpu= 2>/dev/null || echo "")

  # Check each active agent
  for issue in "${!ACTIVE[@]}"; do
    # Stall detection (issue #437): track consecutive low-CPU polls (subtree
    # aggregate <= PIPELINE_STALL_CPU_THRESHOLD) and emit a single latched EVENT
    # line per stall window. Observe-only — no kill.
    cpu=$(get_agent_cpu_pct "$issue" "$PS_SNAPSHOT")
    cpu_int=${cpu%%.*}; cpu_int=${cpu_int:-0}
    # Digit-guard: if ps returned junk, coerce to 0 so the `-le` test below
    # never errors on a non-numeric operand (which would abort the runner).
    case "$cpu_int" in
      ''|*[!0-9]*) cpu_int=0 ;;
    esac
    if [ "$cpu_int" -le "$PIPELINE_STALL_CPU_THRESHOLD" ]; then
      CPU_IDLE_POLLS[$issue]=$(( ${CPU_IDLE_POLLS[$issue]:-0} + 1 ))
      if [ "${CPU_IDLE_POLLS[$issue]}" -ge "$PIPELINE_STALL_POLL_THRESHOLD" ] \
         && [ "${STALL_LATCHED[$issue]:-0}" -eq 0 ]; then
        pid=$(tmux list-panes -t "${PIPELINE_TMUX_SESSION:-dev}:issue-${issue}" -F '#{pane_pid}' 2>/dev/null | head -1)
        window="issue-${issue}"
        elapsed=$(( CPU_IDLE_POLLS[$issue] * POLL_INTERVAL / 60 ))
        log "EVENT: agent-stalled issue=${issue} pid=${pid:-?} window=${window} elapsed=${elapsed}m"
        STALL_LATCHED[$issue]=1
      fi
    else
      CPU_IDLE_POLLS[$issue]=0
      STALL_LATCHED[$issue]=0
    fi

    if evaluator_finished_terminal "$issue"; then
      # Manual-merge / block-* branch (issue #489): the evaluator has finished
      # posting its verdict but the spawned claude child is still alive, so the
      # tmux window never closed on its own. Kill the window so the existing
      # finish-branch invariants hold (window absent => slot free), record the
      # specific outcome, free the bucket slot, and fill the gap. Checked BEFORE
      # is_agent_running so this more-specific signal wins when both are true on
      # the same poll.
      tmux kill-window -t "${PIPELINE_TMUX_SESSION:-dev}:issue-${issue}" 2>/dev/null || true
      outcome="approved-manual-merge"
      RESULTS[$issue]="$outcome"
      _finished_mode="${ISSUE_MODE[$issue]:-bare}"
      BUCKET_ACTIVE[$_finished_mode]=$(( ${BUCKET_ACTIVE[$_finished_mode]:-1} - 1 ))
      unset 'ACTIVE['"$issue"']'
      unset 'CPU_IDLE_POLLS['"$issue"']' 'STALL_LATCHED['"$issue"']'
      log "[$(date +%H:%M:%S)] Agent for issue #${issue} finished — outcome: ${outcome} (evaluator terminal, window force-closed)"
      log "EVENT: agent-finished issue=${issue} outcome=${outcome} mode=${_finished_mode}"
      fill_slots
      continue
    fi

    if ! is_agent_running "$issue"; then
      # Agent finished — check outcome
      outcome=$(check_issue_outcome "$issue")
      RESULTS[$issue]="$outcome"
      _finished_mode="${ISSUE_MODE[$issue]:-bare}"
      BUCKET_ACTIVE[$_finished_mode]=$(( ${BUCKET_ACTIVE[$_finished_mode]:-1} - 1 ))
      unset 'ACTIVE['"$issue"']'
      # Clear stall-tracking state so a re-used issue number can't inherit a
      # stale counter/latch (issue #437).
      unset 'CPU_IDLE_POLLS['"$issue"']' 'STALL_LATCHED['"$issue"']'
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
