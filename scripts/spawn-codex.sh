#!/bin/bash
set -euo pipefail

# spawn-codex.sh — Codex analog of spawn-claude.sh (issue #983, Leg of the Codex
# dual-target migration).
#
# CONTRACT (mirrors spawn-claude.sh, intentionally — callers route through
# dispatch-leaf.sh transport-script and must not care which harness they hit):
#   - same positional argv: <worktree-path> <issue-number> [slug] [mode]
#   - same flag-parse loop: --dangerously-skip-permissions, --skill <name>,
#     --manual-merge, --classifier-passthrough=<token>
#   - same PIPELINE_SPAWN_DRY_RUN=1 dump hook (PATH_LETTER / GENERATED_SESSION_ID /
#     RUNS_LOG / BUILD_ARGV / PAYLOAD)
#   - same runs.log / --session-id emission shape (TSV row, 1:1 join key)
#
# DIVERGENT parts vs spawn-claude.sh (the only intended differences):
#   - launch verb is `codex exec`, NOT `claude -p`.
#   - Codex autonomy flags: a non-interactive Codex run needs its sandbox +
#     approval-policy gates bypassed for unattended autonomy.
#   - --dangerously-bypass-hook-trust: automation paths run hooks WITHOUT a
#     persisted trust prompt (the orchestrator already vetted the worktree).
#
# KNOWN-UNKNOWN: the EXACT Codex CLI flag NAMES are not yet pinned. The literal
# tokens below are best-guess placeholders; what is load-bearing here — and what
# the acceptance suite asserts — is the env/argv SHAPE: the `codex exec` verb,
# the presence of an autonomy/sandbox-bypass token, and the
# --dangerously-bypass-hook-trust token. Re-pin the literals when the Codex CLI
# surface is finalized; keep the shape.

# Run from the consumer repo root (so `$(pwd)/pipeline.config` resolves), or
# export PIPELINE_PROJECT_ROOT to override the lookup directory.
source "${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config"

_spawn_codex_dir="$(dirname "${BASH_SOURCE[0]}")"

# Harness detection primitive (issue #980). source platform.sh when present so a
# downstream branch can key off $PIPELINE_HARNESS; otherwise default to claude
# (this script is the codex transport, but the var is informational here).
if [ -f "${_spawn_codex_dir}/platform.sh" ]; then
  # shellcheck disable=SC1091
  source "${_spawn_codex_dir}/platform.sh"
else
  PIPELINE_HARNESS="${PIPELINE_HARNESS:-claude}"
fi

# Observability logging helper: defines pipeline_logging_enabled(). Fall back to
# an inline definition when the helper is missing (partial install / isolated
# test copy) so we never hard-fail.
if [ -f "${_spawn_codex_dir}/_logging.sh" ]; then
  # shellcheck disable=SC1091
  source "${_spawn_codex_dir}/_logging.sh"
else
  pipeline_logging_enabled() { [ "${PIPELINE_LOGS_ENABLED:-false}" = "true" ]; }
fi

# Self-resolve CLAUDE_PLUGIN_ROOT when callers don't export it. Idempotent.
if [ -f "${_spawn_codex_dir}/_resolve-plugin-root.sh" ]; then
  # shellcheck disable=SC1091
  source "${_spawn_codex_dir}/_resolve-plugin-root.sh"
fi

# Launch a codex CLI session for a worktree.
# Usage: bash ${CLAUDE_PLUGIN_ROOT}/scripts/spawn-codex.sh [--dangerously-skip-permissions] <worktree-path> <issue-number> [slug] [mode]
#   mode: "terminal" (default) — new Terminal.app window with /pipeline:execute-issue-plan
#         "tmux"               — tmux window with auto-fire /pipeline:execute-issue-plan
#         "remote-control"     — remote-control server (control from mobile app)

SKIP_PERMS=""
SKILL="execute-issue-plan"
MANUAL_MERGE_ARG=""
EXTRA_CODEX_ARGV=()
# Loop-based parser — mirrors spawn-claude.sh exactly so the two transports parse
# identical flag sets. --manual-merge exports MANUAL_MERGE=1 for the child;
# --classifier-passthrough=<token> ferries extra CLI tokens into the final argv.
while [ $# -gt 0 ]; do
  case "$1" in
    --dangerously-skip-permissions) SKIP_PERMS="--dangerously-skip-permissions"; shift ;;
    --skill) SKILL="$2"; shift 2 ;;
    --manual-merge) MANUAL_MERGE_ARG="--manual-merge"; shift ;;
    --classifier-passthrough=*) EXTRA_CODEX_ARGV+=("${1#--classifier-passthrough=}"); shift ;;
    *) break ;;
  esac
done
if [ -n "$MANUAL_MERGE_ARG" ]; then
  export MANUAL_MERGE=1
fi

WORKTREE_PATH="$(realpath "$1" 2>/dev/null || echo "$1")"
ISSUE_NUM="$2"
SLUG="${3:-issue-$ISSUE_NUM}"
MODE="${4:-terminal}"
# Executor safety-net timeout (seconds). Configurable via pipeline.config.
EXECUTOR_TIMEOUT="${PIPELINE_EXECUTOR_TIMEOUT_SECONDS:-5400}"
SESSION_NAME="issue-${ISSUE_NUM}-${SLUG}"
TMUX_WINDOW="issue-${ISSUE_NUM}"

# --- Per-agent resource caps via a systemd-run --user scope (issue #918) ---
# Identical seatbelt to spawn-claude.sh: each agent runs inside its OWN transient
# systemd user scope so a runaway is OOM/pid-killed inside its cgroup. Graceful
# degrade to a plain `timeout … codex …` when systemd-run --user is unavailable.
AGENT_MEMORY_MAX="${PIPELINE_AGENT_MEMORY_MAX:-2G}"
AGENT_MEMORY_MAX_BROWSER="${PIPELINE_AGENT_MEMORY_MAX_BROWSER:-4G}"
AGENT_TASKS_MAX="${PIPELINE_AGENT_TASKS_MAX:-512}"
SCOPE_PREFIX=""
SYSTEMD_SCOPE_OK=0
if command -v systemd-run >/dev/null 2>&1 \
   && systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
  SYSTEMD_SCOPE_OK=1
else
  echo "WARNING: systemd-run --user unavailable; launching agent UNBOUNDED (no MemoryMax/TasksMax cgroup ceiling). See /pipeline:doctor for the recommended host seatbelt." >&2
fi

# Set up logging
REPO_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
LOG_DIR="${REPO_ROOT}/.claude/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/issue-${ISSUE_NUM}-${TIMESTAMP}.log"
if pipeline_logging_enabled; then
  mkdir -p "$LOG_DIR"
fi

if [ ! -d "$WORKTREE_PATH" ]; then
  echo "ERROR: Worktree not found at $WORKTREE_PATH"
  exit 1
fi

# --- Build --append-system-prompt payload: label-driven 4-path selection ---
# Identical precedence + collision semantics to spawn-claude.sh (A > D > C > B).
case "$SKILL" in
  execute-issue-plan)   SKILL_ALIAS="EXECUTE" ;;
  evaluate-issue-pr)    SKILL_ALIAS="EVALUATE_PR" ;;
  plan-issue)           SKILL_ALIAS="PLAN" ;;
  evaluate-issue-plan)  SKILL_ALIAS="EVALUATE_PLAN" ;;
  *)                    SKILL_ALIAS="" ;;
esac

PATH_LETTER="B"
if [ -n "$SKILL_ALIAS" ] && [ -n "$ISSUE_NUM" ]; then
  if LABELS="$(gh issue view "$ISSUE_NUM" --repo "$PIPELINE_REPO" --json labels --jq '.labels[].name' 2>/dev/null)"; then
    HAS_DOCS=0
    HAS_QUICK=0
    HAS_MULTI=0
    HAS_NEEDS_BROWSER=0
    while IFS= read -r lbl; do
      [ "$lbl" = "docs-only" ] && HAS_DOCS=1
      [ "$lbl" = "quick-fix" ] && HAS_QUICK=1
      [ "$lbl" = "multi-task" ] && HAS_MULTI=1
      [ "$lbl" = "needs-browser" ] && HAS_NEEDS_BROWSER=1
    done <<< "$LABELS"
    if [ "$HAS_DOCS" = "1" ]; then
      PATH_LETTER="A"
    elif [ "$HAS_QUICK" = "1" ]; then
      PATH_LETTER="D"
    elif [ "$HAS_MULTI" = "1" ]; then
      PATH_LETTER="C"
    fi
    _collision_count=$((HAS_DOCS + HAS_QUICK + HAS_MULTI))
    if [ "$_collision_count" -ge 2 ]; then
      _collision_labels=""
      [ "$HAS_DOCS" = "1" ] && _collision_labels="${_collision_labels:+$_collision_labels, }docs-only"
      [ "$HAS_QUICK" = "1" ] && _collision_labels="${_collision_labels:+$_collision_labels, }quick-fix"
      [ "$HAS_MULTI" = "1" ] && _collision_labels="${_collision_labels:+$_collision_labels, }multi-task"
      if [ "$HAS_DOCS" = "1" ] && [ "$HAS_MULTI" = "1" ] && [ "$HAS_QUICK" = "0" ]; then
        echo "WARNING: issue #$ISSUE_NUM has both docs-only and multi-task labels; picking PATH A" >&2
      else
        echo "WARNING: issue #$ISSUE_NUM has colliding path labels (${_collision_labels}); picking PATH $PATH_LETTER" >&2
      fi
    fi
  else
    echo "[spawn-codex] WARN: gh issue view failed for issue #$ISSUE_NUM, defaulting to PATH B" >&2
  fi
fi

# --- Build SCOPE_PREFIX now that HAS_NEEDS_BROWSER is known (issue #961) ---
EFFECTIVE_MEMORY_MAX="$AGENT_MEMORY_MAX"
[ "${HAS_NEEDS_BROWSER:-0}" = "1" ] && EFFECTIVE_MEMORY_MAX="$AGENT_MEMORY_MAX_BROWSER"
if [ "$SYSTEMD_SCOPE_OK" = "1" ]; then
  SCOPE_PREFIX="systemd-run --user --scope -p MemoryMax=${EFFECTIVE_MEMORY_MAX} -p TasksMax=${AGENT_TASKS_MAX} -- "
fi

# --- Generate session id and bind to CLI via --session-id flag ---
# Same UUID-as-join-key contract as spawn-claude.sh: emit the same UUID into
# runs.log AND pass it to the CLI via --session-id so the three logs join 1:1.
PROC_UUID="/proc/sys/kernel/random/uuid"
if command -v uuidgen >/dev/null 2>&1; then
  GENERATED_SESSION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
elif [ -r "$PROC_UUID" ]; then
  GENERATED_SESSION_ID="$(cat "$PROC_UUID")"
else
  echo "ERROR: neither uuidgen nor the kernel random-uuid pseudo-file is available; cannot generate a valid UUID for --session-id" >&2
  echo "       On Git-Bash install uuidgen via the Git-for-Windows SDK; on Linux install util-linux." >&2
  exit 1
fi

RUNS_LOG="${PIPELINE_RUNS_LOG_OVERRIDE:-${LOG_DIR}/runs.log}"
RUNS_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUNS_MODEL="${MODEL:-}"
if pipeline_logging_enabled; then
  mkdir -p "$(dirname "$RUNS_LOG")"
  printf '%s\tsession=%s\tissue=%s\tpath=%s\tskill=%s\tworktree=%s\tmodel=%s\n' \
    "$RUNS_TS" "$GENERATED_SESSION_ID" "$ISSUE_NUM" "$PATH_LETTER" "$SKILL" "$WORKTREE_PATH" "$RUNS_MODEL" \
    >> "$RUNS_LOG"
fi

# Deferred temp-file cleanup (same detached-reaper shape as spawn-claude.sh).
APPEND_PROMPT_FILE=""
LAUNCHER=""
EMPTY_MCP_FILE=""
cleanup_temp_files() {
  local files=()
  [ -n "$APPEND_PROMPT_FILE" ] && files+=("$APPEND_PROMPT_FILE")
  [ -n "$LAUNCHER" ] && files+=("$LAUNCHER")
  [ -n "$EMPTY_MCP_FILE" ] && files+=("$EMPTY_MCP_FILE")
  [ ${#files[@]} -eq 0 ] && return 0
  if command -v setsid >/dev/null 2>&1; then
    setsid -f bash -c "sleep 60; rm -f $(printf '%q ' "${files[@]}")" </dev/null >/dev/null 2>&1 &
  else
    nohup bash -c "sleep 60; rm -f $(printf '%q ' "${files[@]}")" </dev/null >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
}
trap cleanup_temp_files EXIT

if [ -n "$SKILL_ALIAS" ]; then
  skills_var="PIPELINE_PATH_${PATH_LETTER}_SKILLS_${SKILL_ALIAS}"
  reviewer_var="PIPELINE_PATH_${PATH_LETTER}_REVIEWER_${SKILL_ALIAS}"
  REQUIRED_SKILLS="${!skills_var:-}"
  REVIEWER="${!reviewer_var:-}"

  if [ -n "$REQUIRED_SKILLS" ] || [ -n "$REVIEWER" ]; then
    APPEND_PROMPT_FILE=$(mktemp /tmp/codex-sysprompt-XXXXXX.txt)
    {
      if [ -n "$REQUIRED_SKILLS" ]; then
        echo "REQUIRED STARTUP SEQUENCE: Your first tool calls MUST be Skill invocations, in order:"
        for sk in $REQUIRED_SKILLS; do
          norm="$(echo "${sk#superpowers:}" | tr '[:lower:]-' '[:upper:]_')"
          args_var="PIPELINE_PATH_${PATH_LETTER}_SKILL_ARGS_${SKILL_ALIAS}_${norm}"
          args_path="${!args_var:-}"
          if [ -n "$args_path" ] && [ -f "${REPO_ROOT}/${args_path}" ]; then
            args_content="$(cat "${REPO_ROOT}/${args_path}")"
            esc="${args_content//\\/\\\\}"
            esc="${esc//\"/\\\"}"
            esc="${esc//$'\n'/\\n}"
            echo "  - Skill(skill: \"${sk}\", args: \"${esc}\")"
          elif [ -n "$args_path" ]; then
            echo "WARNING: args file not found for ${sk}: ${args_path}" >&2
            echo "  - Skill(skill: \"${sk}\")"
          else
            echo "  - Skill(skill: \"${sk}\")"
          fi
        done
        echo "Do NOT call Read, Edit, Write, Bash, Grep, Glob, or any other tool until every listed Skill has returned. Only then proceed with the /slash-command."
      fi

      if [ -n "$REVIEWER" ]; then
        [ -n "$REQUIRED_SKILLS" ] && echo ""
        echo "REQUIRED FINAL STEP: After all work is complete and before reporting back, your FINAL tool call MUST be:"
        echo "  - Agent(subagent_type: \"${REVIEWER}\", description: \"Code-review the completed work for issue #${ISSUE_NUM} against the approved plan. Flag plan-compliance gaps and code-quality issues. Do not refactor.\")"
        echo "Only after this Agent() call returns may you post status comments, update labels, or conclude."
      fi
    } > "$APPEND_PROMPT_FILE"
  fi
fi

# CI-fix mode (issue #52): same follow-up-commit directive as spawn-claude.sh.
if [ -n "${PIPELINE_CI_FIX_CONTEXT:-}" ]; then
  if [ -z "$APPEND_PROMPT_FILE" ]; then
    APPEND_PROMPT_FILE=$(mktemp /tmp/codex-sysprompt-XXXXXX.txt)
  fi
  {
    echo ""
    echo "---"
    echo "CI-FIX MODE: A prior commit on this branch failed CI. Read the failure log at"
    echo "${PIPELINE_CI_FIX_CONTEXT} and the current PR diff (gh pr diff), then push a"
    echo "follow-up commit to the existing branch. Do NOT open a new PR. Do NOT remove"
    echo "the pr-open label. Stay inside this worktree. Apply red->green->commit TDD"
    echo "discipline to the fix itself."
    echo "---"
  } >> "$APPEND_PROMPT_FILE"
fi

# Build-codex-argv snippet injected into each mode's launcher.
#
# LAUNCH_CMD wraps `codex exec` (the Codex non-interactive launch verb), in
# contrast to spawn-claude.sh's bare `claude`. The autonomy/sandbox-bypass and
# --dangerously-bypass-hook-trust tokens are appended UNCONDITIONALLY because an
# unattended automation run has no interactive approval surface.
#
# KNOWN-UNKNOWN: the literal flag tokens below are best-guess placeholders for
# the real Codex CLI surface; the SHAPE (verb + bypass tokens) is what is
# contractually asserted. Re-pin the literals when the surface is finalized.
#
# Codex autonomy tokens (best-guess literals; re-pin when finalized):
#   --sandbox danger-full-access  -> disable the filesystem sandbox for autonomy
#   --ask-for-approval never      -> never block on an interactive approval prompt
#   --dangerously-bypass-hook-trust -> run hooks without a persisted trust prompt
CODEX_AUTONOMY_ARGV=(--sandbox danger-full-access --ask-for-approval never --dangerously-bypass-hook-trust)
_launch_cmd_quoted="codex exec"
_autonomy_argv_lines=""
for tok in ${CODEX_AUTONOMY_ARGV[@]+"${CODEX_AUTONOMY_ARGV[@]}"}; do
  _autonomy_argv_lines+="CODEX_ARGV+=($(printf '%q' "$tok"))"$'\n'
done
_extra_argv_lines=""
for tok in ${EXTRA_CODEX_ARGV[@]+"${EXTRA_CODEX_ARGV[@]}"}; do
  _extra_argv_lines+="CODEX_ARGV+=($(printf '%q' "$tok"))"$'\n'
done
BUILD_ARGV='
declare -a CODEX_ARGV
declare -a LAUNCH_CMD=('"$_launch_cmd_quoted"')
[ -n "'"$SKIP_PERMS"'" ] && CODEX_ARGV+=("'"$SKIP_PERMS"'")
# Surface session metadata to in-session hooks.
export CLAUDE_PIPELINE_ISSUE_NUMBER='"$ISSUE_NUM"'
export CLAUDE_PIPELINE_SKILL='"$SKILL"'
echo "[spawn-codex-canary] CLAUDE_PIPELINE_ISSUE_NUMBER=${CLAUDE_PIPELINE_ISSUE_NUMBER:-UNSET} CLAUDE_PIPELINE_SKILL=${CLAUDE_PIPELINE_SKILL:-UNSET}" >&2
SYSPROMPT_FILE="'"$APPEND_PROMPT_FILE"'"
if [ -n "$SYSPROMPT_FILE" ] && [ -f "$SYSPROMPT_FILE" ]; then
  CODEX_ARGV+=(--append-system-prompt "$(cat "$SYSPROMPT_FILE")")
fi
CODEX_ARGV+=(--session-id '"'"''"$GENERATED_SESSION_ID"''"'"')
'"$_autonomy_argv_lines$_extra_argv_lines"

# Test hook: dump resolved state and exit before launching anything.
if [ "${PIPELINE_SPAWN_DRY_RUN:-}" = "1" ]; then
  echo "PATH_LETTER=$PATH_LETTER"
  echo "GENERATED_SESSION_ID=$GENERATED_SESSION_ID"
  echo "RUNS_LOG=$RUNS_LOG"
  echo "RUNS_LOG_LINE=$(tail -1 "$RUNS_LOG")"
  echo "SYSPROMPT_FILE=$APPEND_PROMPT_FILE"
  echo "EMPTY_MCP_FILE=$EMPTY_MCP_FILE"
  echo "AGENT_MEMORY_MAX=$AGENT_MEMORY_MAX"
  echo "AGENT_MEMORY_MAX_BROWSER=$AGENT_MEMORY_MAX_BROWSER"
  echo "AGENT_TASKS_MAX=$AGENT_TASKS_MAX"
  echo "SCOPE_PREFIX=$SCOPE_PREFIX"
  echo "PIPELINE_HARNESS=${PIPELINE_HARNESS:-}"
  echo "=== BUILD_ARGV ==="
  echo "$BUILD_ARGV"
  echo "=== END BUILD_ARGV ==="
  if [ -n "$APPEND_PROMPT_FILE" ] && [ -f "$APPEND_PROMPT_FILE" ]; then
    echo "=== PAYLOAD ==="
    cat "$APPEND_PROMPT_FILE"
    echo "=== END PAYLOAD ==="
  fi
  exit 0
fi

# Write a temp launcher script to avoid nested quoting issues with tmux
LAUNCHER=$(mktemp /tmp/codex-launch-XXXXXX.sh)
chmod +x "$LAUNCHER"

if pipeline_logging_enabled; then
  LAUNCHER_BANNER_TERMINAL="echo \"=== Session started: \$(date) ===\" >> ${LOG_FILE}
echo \"=== Issue: #${ISSUE_NUM} | Skill: ${SKILL} | Mode: terminal | Worktree: ${WORKTREE_PATH} ===\" >> ${LOG_FILE}"
  LAUNCHER_BANNER_REMOTECTL="echo \"=== Session started: \$(date) ===\" >> ${LOG_FILE}
echo \"=== Issue: #${ISSUE_NUM} | Skill: ${SKILL} | Mode: remote-control | Worktree: ${WORKTREE_PATH} ===\" >> ${LOG_FILE}"
  LAUNCHER_BANNER_TMUX="echo \"=== Session started: \$(date) ===\" >> ${LOG_FILE}
echo \"=== Issue: #${ISSUE_NUM} | Skill: ${SKILL} | Mode: tmux | Worktree: ${WORKTREE_PATH} ===\" >> ${LOG_FILE}"
  LAUNCHER_EXEC_DARWIN="exec script -a ${LOG_FILE} bash -c \"\$CMD\""
  LAUNCHER_EXEC_LINUX="SHELL=/bin/bash exec script -a ${LOG_FILE} -c \"\$CMD\""
else
  LAUNCHER_BANNER_TERMINAL="# session-start banner suppressed (PIPELINE_LOGS_ENABLED=false)"
  LAUNCHER_BANNER_REMOTECTL="# session-start banner suppressed (PIPELINE_LOGS_ENABLED=false)"
  LAUNCHER_BANNER_TMUX="# session-start banner suppressed (PIPELINE_LOGS_ENABLED=false)"
  LAUNCHER_EXEC_DARWIN="exec bash -c \"\$CMD\""
  LAUNCHER_EXEC_LINUX="SHELL=/bin/bash exec bash -c \"\$CMD\""
fi

if [ "$MODE" = "terminal" ]; then
  cat > "$LAUNCHER" <<SCRIPT
#!/bin/bash
cd ${WORKTREE_PATH}
${LAUNCHER_BANNER_TERMINAL}
${BUILD_ARGV}
CODEX_ARGV+=('/pipeline:${SKILL} ${ISSUE_NUM}')
CMD=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CODEX_ARGV[@]}")
CMD="\${CMD# }"
if [ "\$(uname -s)" = "Darwin" ]; then
  ${LAUNCHER_EXEC_DARWIN}
else
  ${LAUNCHER_EXEC_LINUX}
fi
SCRIPT

  if command -v osascript &>/dev/null; then
    osascript -e "tell application \"Terminal\" to do script \"${LAUNCHER}\""
  else
    if [ -n "$PIPELINE_WIN_TEMP" ]; then
      WIN_TMPDIR="$PIPELINE_WIN_TEMP"
      WIN_BAT="${WIN_TMPDIR}/launch-${ISSUE_NUM}.bat"
      WIN_WORKTREE="$(cygpath -w ${WORKTREE_PATH})"
      BASH_EXE="C:\\Program Files\\Git\\bin\\bash.exe"
      cat > "$WIN_BAT" << BATEOF
@echo off
cd /d "${WIN_WORKTREE}"
"${BASH_EXE}" "${LAUNCHER}"
BATEOF
      WIN_BAT_W="$(cygpath -w "$WIN_BAT")"
      powershell.exe -NoProfile -Command "Start-Process wt.exe -ArgumentList 'new-tab', '--title', 'issue-${ISSUE_NUM}', '--', 'C:\Windows\System32\cmd.exe', '/k', '${WIN_BAT_W}'"
    else
      echo "WARNING: Windows launcher not configured. Set PIPELINE_WIN_TEMP in pipeline.config."
    fi
  fi
  echo "Launched terminal window for issue #${ISSUE_NUM} (interactive)"
  echo "  Session: ${SESSION_NAME}"
  if pipeline_logging_enabled; then echo "  Log: ${LOG_FILE}"; fi

elif [ "$MODE" = "remote-control" ]; then
  cat > "$LAUNCHER" <<SCRIPT
#!/bin/bash
cd ${WORKTREE_PATH}
${LAUNCHER_BANNER_REMOTECTL}
${BUILD_ARGV}
CODEX_ARGV+=(remote-control --name '${SESSION_NAME}' --spawn same-dir)
CMD=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CODEX_ARGV[@]}")
CMD="\${CMD# }"
if [ "\$(uname -s)" = "Darwin" ]; then
  ${LAUNCHER_EXEC_DARWIN}
else
  ${LAUNCHER_EXEC_LINUX}
fi
SCRIPT

  if command -v tmux &>/dev/null && tmux has-session -t "${PIPELINE_TMUX_SESSION:-dev}" 2>/dev/null; then
    tmux new-window -t "${PIPELINE_TMUX_SESSION:-dev}" -n "$TMUX_WINDOW" "$LAUNCHER"
    echo "Launched remote-control session for issue #${ISSUE_NUM} (tmux)"
    echo "  tmux window: ${PIPELINE_TMUX_SESSION:-dev}:${TMUX_WINDOW}"
  else
    osascript -e "tell application \"Terminal\" to do script \"${LAUNCHER}\""
    echo "Launched remote-control session for issue #${ISSUE_NUM} (Terminal.app)"
  fi
  if pipeline_logging_enabled; then echo "  Log: ${LOG_FILE}"; fi
  echo "  Connect from Claude app or claude.ai/code → session: ${SESSION_NAME}"

elif [ "$MODE" = "tmux" ]; then
  if ! tmux has-session -t "${PIPELINE_TMUX_SESSION:-dev}" 2>/dev/null; then
    echo "ERROR: No tmux session named '${PIPELINE_TMUX_SESSION:-dev}'. Start one with: tmux new -s ${PIPELINE_TMUX_SESSION:-dev}"
    rm -f "$LAUNCHER"
    exit 1
  fi

  cat > "$LAUNCHER" <<SCRIPT
#!/bin/bash
cd ${WORKTREE_PATH}
${LAUNCHER_BANNER_TMUX}
${BUILD_ARGV}
CODEX_ARGV+=('/pipeline:${SKILL} ${ISSUE_NUM}')
INNER=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CODEX_ARGV[@]}")
INNER="\${INNER# }"
# timeout safety net: \${SCOPE_PREFIX} (resolved in the spawning shell) wraps the
# whole timeout->codex tree in a systemd-run --user scope; collapses to a clean
# "timeout …" when unavailable (graceful degrade, #918).
CMD="${SCOPE_PREFIX}timeout --foreground --signal=TERM --kill-after=30 ${EXECUTOR_TIMEOUT} \$INNER"
if [ "\$(uname -s)" = "Darwin" ]; then
  ${LAUNCHER_EXEC_DARWIN}
else
  ${LAUNCHER_EXEC_LINUX}
fi
SCRIPT

  tmux new-window -t "${PIPELINE_TMUX_SESSION:-dev}" -n "$TMUX_WINDOW" "$LAUNCHER"
  echo "Launched tmux session for issue #${ISSUE_NUM}"
  echo "  tmux window: ${PIPELINE_TMUX_SESSION:-dev}:${TMUX_WINDOW}"
  if pipeline_logging_enabled; then echo "  Log: ${LOG_FILE}"; fi

else
  rm -f "$LAUNCHER"
  echo "ERROR: Unknown mode '$MODE'. Use: terminal, tmux, or remote-control"
  exit 1
fi
