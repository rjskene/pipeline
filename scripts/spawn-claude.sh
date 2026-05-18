#!/bin/bash
set -euo pipefail

# Run from the consumer repo root (so `$(pwd)/pipeline.config` resolves), or
# export PIPELINE_PROJECT_ROOT to override the lookup directory.
source "${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config"

# Launch a claude CLI session for a worktree.
# Usage: bash ${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh [--dangerously-skip-permissions] <worktree-path> <issue-number> [slug] [mode]
#   mode: "terminal" (default) — new Terminal.app window with /pipeline:execute-issue-plan
#         "tmux"               — tmux window with auto-fire /pipeline:execute-issue-plan
#         "remote-control"     — remote-control server (control from mobile app / claude.ai/code)

SKIP_PERMS=""
SKILL="execute-issue-plan"
MANUAL_MERGE_ARG=""
CONTAINER_MODE=""
EXTRA_CLAUDE_ARGV=()
# Loop-based parser: --manual-merge may appear anywhere before the
# positional <worktree-path> argument. When present, MANUAL_MERGE=1 is
# exported to the child claude process; the skill's prose-level parser
# in evaluate-issue-pr Step 11 honors that env var as equivalent to the
# --manual-merge flag. The case-arm explicitly consumes --manual-merge
# before any unknown-arg fallback, so stale installs that don't know the
# flag degrade safely.
#
# --container-mode=<name> (issue #218) selects a consumer-declared container
# from PIPELINE_EVAL_CONTAINERS. Only meaningful with --skill=evaluate-issue-pr
# (other skills reject the flag). --classifier-passthrough=<token> is the
# wrapper format the pre-spawn classifier uses to ferry extra claude-CLI
# tokens through run-queue.sh into the final CLAUDE_ARGV.
while [ $# -gt 0 ]; do
  case "$1" in
    --dangerously-skip-permissions) SKIP_PERMS="--dangerously-skip-permissions"; shift ;;
    --skill) SKILL="$2"; shift 2 ;;
    --manual-merge) MANUAL_MERGE_ARG="--manual-merge"; shift ;;
    --container-mode=*) CONTAINER_MODE="${1#--container-mode=}"; shift ;;
    --classifier-passthrough=*) EXTRA_CLAUDE_ARGV+=("${1#--classifier-passthrough=}"); shift ;;
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
SESSION_NAME="issue-${ISSUE_NUM}-${SLUG}"
TMUX_WINDOW="issue-${ISSUE_NUM}"

# Set up logging
REPO_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
LOG_DIR="${REPO_ROOT}/.claude/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/issue-${ISSUE_NUM}-${TIMESTAMP}.log"

if [ ! -d "$WORKTREE_PATH" ]; then
  echo "ERROR: Worktree not found at $WORKTREE_PATH"
  exit 1
fi

# --- Build --append-system-prompt payload: label-driven 3-path selection ---
#
# spawn-claude.sh reads the issue's GitHub labels and picks one of three
# execution paths:
#   docs-only  -> PATH A (trivial; verification-only, no TDD gate)
#   multi-task -> PATH C (SDD wiring: one implementer subagent per task)
#   else       -> PATH B (standard; TDD mandatory)
# If both docs-only and multi-task are set, PATH A wins (narrower; safer to
# over-apply) and a stderr warning is logged so the collision is visible.
# If `gh issue view` fails (offline/auth), a stderr warning is logged and
# PATH B is used as the safe default.
#
# For the picked path, the script looks up:
#   PIPELINE_PATH_<X>_SKILLS_<ALIAS>             - space-separated skills to
#                                                  require at session START.
#   PIPELINE_PATH_<X>_REVIEWER_<ALIAS>           - single subagent name to
#                                                  dispatch as the session's
#                                                  FINAL tool call.
#   PIPELINE_PATH_<X>_SKILL_ARGS_<ALIAS>_<NORM>  - path to plain-text args
#                                                  file for each skill.
# The resulting system-prompt payload is written to a temp file; the launcher
# reads it at run time and injects it as an argv element to avoid shell-quoting
# hazards with multi-line / special-character content.
case "$SKILL" in
  execute-issue-plan)   SKILL_ALIAS="EXECUTE" ;;
  evaluate-issue-pr)    SKILL_ALIAS="EVALUATE_PR" ;;
  plan-issue)           SKILL_ALIAS="PLAN" ;;
  evaluate-issue-plan)  SKILL_ALIAS="EVALUATE_PLAN" ;;
  *)                    SKILL_ALIAS="" ;;
esac

# Label -> PATH mapping.
PATH_LETTER="B"
if [ -n "$SKILL_ALIAS" ] && [ -n "$ISSUE_NUM" ]; then
  if LABELS="$(gh issue view "$ISSUE_NUM" --repo "$PIPELINE_REPO" --json labels --jq '.labels[].name' 2>/dev/null)"; then
    HAS_DOCS=0
    HAS_MULTI=0
    while IFS= read -r lbl; do
      [ "$lbl" = "docs-only" ] && HAS_DOCS=1
      [ "$lbl" = "multi-task" ] && HAS_MULTI=1
    done <<< "$LABELS"
    if [ "$HAS_DOCS" = "1" ] && [ "$HAS_MULTI" = "1" ]; then
      echo "WARNING: issue #$ISSUE_NUM has both docs-only and multi-task labels; picking PATH A" >&2
      PATH_LETTER="A"
    elif [ "$HAS_DOCS" = "1" ]; then
      PATH_LETTER="A"
    elif [ "$HAS_MULTI" = "1" ]; then
      PATH_LETTER="C"
    fi
  else
    echo "[spawn-claude] WARN: gh issue view failed for issue #$ISSUE_NUM, defaulting to PATH B" >&2
  fi
fi

# --- Generate session id and bind to CLI via --session-id flag ---
# The claude CLI's --session-id flag (verified in claude --help) accepts a UUID
# and makes that the session_id present in every PostToolUse hook payload, which
# log-tool-use.sh and log_subagent.py key their TSV rows on. Emitting the same
# UUID to runs.log is therefore a reliable 1:1 join key across all three logs.
# Single-line `>>` appends under PIPE_BUF (4096B on Linux) are atomic, so the
# 3-way concurrency in run-queue.sh.template is race-safe without a lockfile.
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
printf '%s\tsession=%s\tissue=%s\tpath=%s\tskill=%s\tworktree=%s\n' \
  "$RUNS_TS" "$GENERATED_SESSION_ID" "$ISSUE_NUM" "$PATH_LETTER" "$SKILL" "$WORKTREE_PATH" \
  >> "$RUNS_LOG"

# Deferred temp-file cleanup.
#
# Both $APPEND_PROMPT_FILE and $LAUNCHER must outlive this script: the terminal /
# tmux / powershell invocation below fires the launcher asynchronously, and the
# launcher itself reads $APPEND_PROMPT_FILE at argv-build time (via
# `$(cat "$SYSPROMPT_FILE")`). A synchronous `trap 'rm -f ...' EXIT` would
# delete them before the spawned process consumes them.
#
# Instead, on EXIT we fork a fully detached background process that sleeps long
# enough for the launcher to run and read the files, then removes them. `setsid`
# (Linux/Git-Bash) / `nohup` fallback detaches it from the parent shell so it
# survives the spawn script's exit; `disown` removes it from the job table.
APPEND_PROMPT_FILE=""
LAUNCHER=""
cleanup_temp_files() {
  local files=()
  [ -n "$APPEND_PROMPT_FILE" ] && files+=("$APPEND_PROMPT_FILE")
  [ -n "$LAUNCHER" ] && files+=("$LAUNCHER")
  [ ${#files[@]} -eq 0 ] && return 0
  # 60s is ~1000x longer than any realistic launcher cold-start.
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
    APPEND_PROMPT_FILE=$(mktemp /tmp/claude-sysprompt-XXXXXX.txt)
    {
      if [ -n "$REQUIRED_SKILLS" ]; then
        echo "REQUIRED STARTUP SEQUENCE: Your first tool calls MUST be Skill invocations, in order:"
        for sk in $REQUIRED_SKILLS; do
          norm="$(echo "${sk#superpowers:}" | tr '[:lower:]-' '[:upper:]_')"
          args_var="PIPELINE_PATH_${PATH_LETTER}_SKILL_ARGS_${SKILL_ALIAS}_${norm}"
          args_path="${!args_var:-}"
          # Args-file lookup has three cases:
          #   1. Configured + exists on disk -> embed file contents as Skill() args.
          #   2. Configured but file is missing -> degrade gracefully: warn to
          #      stderr so the operator sees the misconfiguration, then emit the
          #      Skill() line WITHOUT args=. The skill still fires; it just runs
          #      without its project-specific directive. This avoids a hard
          #      failure at spawn time when an args path is typo'd or the file
          #      was deleted, and keeps the pipeline moving so the human can fix
          #      the config in a follow-up.
          #   3. Not configured at all -> emit Skill() without args=.
          if [ -n "$args_path" ] && [ -f "${REPO_ROOT}/${args_path}" ]; then
            args_content="$(cat "${REPO_ROOT}/${args_path}")"
            # Escape for embedding in a quoted Skill() args string:
            # backslashes first, then " -> \", then newlines -> literal \n
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

# CI-fix mode (issue #52): when PIPELINE_CI_FIX_CONTEXT is set, append a
# directive that tells the executor to read the failure log + PR diff and
# push a follow-up commit to the existing branch instead of opening a new
# PR. Creates the system-prompt file if no other directive populated it.
if [ -n "${PIPELINE_CI_FIX_CONTEXT:-}" ]; then
  if [ -z "$APPEND_PROMPT_FILE" ]; then
    APPEND_PROMPT_FILE=$(mktemp /tmp/claude-sysprompt-XXXXXX.txt)
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

# --- Container-mode dispatch (issue #218) ---
# When --container-mode=<name> is set, validate the name against
# PIPELINE_EVAL_CONTAINERS, run the optional preflight, and build a
# `docker compose run --rm ... <service>` prefix that wraps the `claude`
# launch invocation. The prefix is exported through BUILD_ARGV as the
# LAUNCH_CMD bash array, which each launcher mode uses in place of the
# bare `claude` executable when emitting the final CMD.
DOCKER_PREFIX=()
if [ -n "$CONTAINER_MODE" ] && [ "$SKILL" != "evaluate-issue-pr" ]; then
  # Container mode is only meaningful when evaluating PRs; rejecting
  # other skills early prevents a containerized executor from being
  # spawned by mistake (unbounded blast radius, not what consumers ask).
  echo "[spawn-claude] ERROR: container-mode is only supported with --skill=evaluate-issue-pr (got --skill=$SKILL)" >&2
  exit 4
fi
# --- container-mode-required enforcement (issue #238) ---
# When PIPELINE_EVAL_CLASSIFIER is set and the operator launched
# evaluate-issue-pr WITHOUT --container-mode=<name>, re-run the classifier
# to ask "would you have emitted a container-mode token?" If yes, fail
# closed with exit 5. Blocks the silent bare-host-evaluator-runs-and-approves
# race documented in #238: a stale consumer-copy of this script that
# lacks --container-mode parsing would otherwise pre-empt the operator's
# container-path re-dispatch. Fail-open when the classifier is unset, the
# skill is not evaluate-issue-pr, the flag is already set, or the
# eval-classifier-invoke.sh shim is missing / exits non-zero.
if [ -z "$CONTAINER_MODE" ] \
   && [ "$SKILL" = "evaluate-issue-pr" ] \
   && [ -n "${PIPELINE_EVAL_CLASSIFIER:-}" ]; then
  _classifier_invoke="${REPO_ROOT}/scripts/eval-classifier-invoke.sh"
  if [ -f "$_classifier_invoke" ]; then
    set +e
    _classifier_out="$(PIPELINE_EVAL_CLASSIFIER="$PIPELINE_EVAL_CLASSIFIER" PIPELINE_REPO="${PIPELINE_REPO:-}" bash "$_classifier_invoke" "$ISSUE_NUM" 2>/dev/null)"
    _classifier_rc=$?
    set -e
    if [ "$_classifier_rc" -eq 0 ] && \
       printf '%s\n' "$_classifier_out" | grep -q '^--container-mode='; then
      _wanted_mode="$(printf '%s\n' "$_classifier_out" | grep '^--container-mode=' | head -1)"
      echo "[spawn-claude] ERROR: classifier wants container dispatch but --container-mode not passed" >&2
      echo "  classifier emitted: ${_wanted_mode}" >&2
      echo "  Re-run by piping the classifier output (bash \${CLAUDE_PLUGIN_ROOT:-.}/scripts/eval-classifier-invoke.sh ${ISSUE_NUM}) into the spawn-claude.sh invocation as a leading argument before --skill evaluate-issue-pr" >&2
      exit 5
    fi
  fi
fi
if [ -n "$CONTAINER_MODE" ]; then
  if ! printf '%s\n' ${PIPELINE_EVAL_CONTAINERS:-} | tr ' ' '\n' | grep -qx "$CONTAINER_MODE"; then
    echo "[spawn-claude] ERROR: container-mode '$CONTAINER_MODE' not declared in PIPELINE_EVAL_CONTAINERS" >&2
    exit 4
  fi
  norm_mode="$(echo "$CONTAINER_MODE" | tr '-' '_')"
  compose_var="PIPELINE_EVAL_CONTAINER_${norm_mode}_COMPOSE_FILE"
  env_var="PIPELINE_EVAL_CONTAINER_${norm_mode}_ENV_FILE"
  svc_var="PIPELINE_EVAL_CONTAINER_${norm_mode}_SERVICE"
  pre_var="PIPELINE_EVAL_CONTAINER_${norm_mode}_PREFLIGHT_CMD"
  COMPOSE_FILE="${!compose_var:-}"
  ENV_FILE="${!env_var:-}"
  SERVICE="${!svc_var:-}"
  PREFLIGHT="${!pre_var:-}"
  # Resolve a relative ENV_FILE to absolute against REPO_ROOT BEFORE
  # DOCKER_PREFIX is assembled. The launcher does `cd $WORKTREE_PATH` before
  # exec, so a relative --env-file value would otherwise resolve under the
  # worktree (not the project root where the file lives). Absolute paths are
  # passed through verbatim. (#257)
  if [ -n "$ENV_FILE" ] && [[ "$ENV_FILE" != /* ]]; then
    ENV_FILE="$REPO_ROOT/$ENV_FILE"
  fi
  if [ -z "$COMPOSE_FILE" ]; then
    echo "[spawn-claude] ERROR: COMPOSE_FILE required for mode=$CONTAINER_MODE (set $compose_var)" >&2
    exit 4
  fi
  if [ -z "$SERVICE" ]; then
    echo "[spawn-claude] ERROR: SERVICE required for mode=$CONTAINER_MODE (set $svc_var)" >&2
    exit 4
  fi
  if [ -n "$PREFLIGHT" ]; then
    echo "PREFLIGHT: running ($PREFLIGHT)" >&2
    if PIPELINE_PROJECT_ROOT="$REPO_ROOT" PIPELINE_WORKTREE_PATH="$WORKTREE_PATH" bash -c "$PREFLIGHT"; then
      echo "PREFLIGHT: pass" >&2
    else
      rc=$?
      echo "[spawn-claude] ERROR: container-mode preflight failed (rc=$rc) for mode=$CONTAINER_MODE" >&2
      exit "$rc"
    fi
  fi
  DOCKER_PREFIX=(docker compose)
  [ -n "$ENV_FILE" ] && DOCKER_PREFIX+=(--env-file "$ENV_FILE")
  DOCKER_PREFIX+=(-f "$COMPOSE_FILE" run --rm \
    -e "CLAUDE_PIPELINE_ISSUE_NUMBER=$ISSUE_NUM" \
    -e "CLAUDE_PIPELINE_SKILL=$SKILL" \
    -e "PIPELINE_PROJECT_ROOT=$REPO_ROOT" \
    -e "PIPELINE_WORKTREE_PATH=$WORKTREE_PATH")
  # Bug 2 (#257): propagate --manual-merge into the containerized evaluator.
  # The host export at line 43 only affects this script's env, not the
  # in-container claude process; docker compose run isolates env unless we
  # pass -e explicitly. Insert BEFORE "$SERVICE" so compose treats it as a
  # per-run env var, not a positional arg to the service.
  if [ -n "$MANUAL_MERGE_ARG" ]; then
    DOCKER_PREFIX+=(-e "MANUAL_MERGE=1")
  fi
  DOCKER_PREFIX+=("$SERVICE")
fi

# Build-claude-argv snippet injected into each mode's launcher. Using bash
# arrays + printf %q keeps multi-line system-prompt payloads intact.
# $SYSPROMPT_FILE is the payload file path, or empty when no directive applies.
# The --session-id flag binds the claude CLI's session_id to the UUID we
# emitted into runs.log, so PostToolUse hook payloads join 1:1 across
# tool-use.log / subagents.log and runs.log.
#
# LAUNCH_CMD wraps `claude` so the launcher can transparently invoke either
# the bare CLI or a containerized variant (`docker compose run --rm ...
# <service> claude`) depending on whether --container-mode was passed.
# EXTRA_CLAUDE_ARGV holds tokens forwarded from the pre-spawn classifier via
# --classifier-passthrough=<token>; they are appended verbatim.
_launch_cmd_quoted="claude"
if [ ${#DOCKER_PREFIX[@]} -gt 0 ]; then
  _launch_cmd_quoted="$(printf '%q ' "${DOCKER_PREFIX[@]}")claude"
fi
# One `CLAUDE_ARGV+=(<tok>)` line per classifier-passthrough token.
_extra_argv_lines=""
for tok in ${EXTRA_CLAUDE_ARGV[@]+"${EXTRA_CLAUDE_ARGV[@]}"}; do
  _extra_argv_lines+="CLAUDE_ARGV+=($(printf '%q' "$tok"))"$'\n'
done
BUILD_ARGV='
declare -a CLAUDE_ARGV
declare -a LAUNCH_CMD=('"$_launch_cmd_quoted"')
[ -n "'"$SKIP_PERMS"'" ] && CLAUDE_ARGV+=("'"$SKIP_PERMS"'")
# Surface session metadata to in-session hooks (e.g. enforce-path-c-delegation.py).
# Both vars are inherited by the claude CLI and by any hook subprocess it spawns.
export CLAUDE_PIPELINE_ISSUE_NUMBER='"$ISSUE_NUM"'
export CLAUDE_PIPELINE_SKILL='"$SKILL"'
# Canary line: if `script -c` strips env on some shell, this shows up in the log
# with UNSET sentinels so the operator can spot the regression.
echo "[spawn-claude-canary] CLAUDE_PIPELINE_ISSUE_NUMBER=${CLAUDE_PIPELINE_ISSUE_NUMBER:-UNSET} CLAUDE_PIPELINE_SKILL=${CLAUDE_PIPELINE_SKILL:-UNSET}" >&2
SYSPROMPT_FILE="'"$APPEND_PROMPT_FILE"'"
if [ -n "$SYSPROMPT_FILE" ] && [ -f "$SYSPROMPT_FILE" ]; then
  CLAUDE_ARGV+=(--append-system-prompt "$(cat "$SYSPROMPT_FILE")")
fi
CLAUDE_ARGV+=(--session-id '"'"''"$GENERATED_SESSION_ID"''"'"')
'"$_extra_argv_lines"

# Test hook: dump resolved state and exit before launching anything.
if [ "${PIPELINE_SPAWN_DRY_RUN:-}" = "1" ]; then
  echo "PATH_LETTER=$PATH_LETTER"
  echo "GENERATED_SESSION_ID=$GENERATED_SESSION_ID"
  echo "RUNS_LOG=$RUNS_LOG"
  echo "RUNS_LOG_LINE=$(tail -1 "$RUNS_LOG")"
  echo "SYSPROMPT_FILE=$APPEND_PROMPT_FILE"
  echo "CONTAINER_MODE=$CONTAINER_MODE"
  if [ ${#DOCKER_PREFIX[@]} -gt 0 ]; then
    # Flattened DOCKER_PREFIX so tests can substring-match individual tokens.
    echo "DOCKER_PREFIX=${DOCKER_PREFIX[*]}"
  fi
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
LAUNCHER=$(mktemp /tmp/claude-launch-XXXXXX.sh)
chmod +x "$LAUNCHER"

if [ "$MODE" = "terminal" ]; then
  cat > "$LAUNCHER" <<SCRIPT
#!/bin/bash
cd ${WORKTREE_PATH}
echo "=== Session started: \$(date) ===" >> ${LOG_FILE}
echo "=== Issue: #${ISSUE_NUM} | Skill: ${SKILL} | Mode: terminal | Worktree: ${WORKTREE_PATH} ===" >> ${LOG_FILE}
${BUILD_ARGV}
CLAUDE_ARGV+=('/pipeline:${SKILL} ${ISSUE_NUM}')
CMD=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CLAUDE_ARGV[@]}")
CMD="\${CMD# }"
if [ "\$(uname -s)" = "Darwin" ]; then
  exec script -a ${LOG_FILE} bash -c "\$CMD"
else
  # printf %q emits \$'...' ANSI-C quoting, so force script to use bash (not dash)
  SHELL=/bin/bash exec script -a ${LOG_FILE} -c "\$CMD"
fi
SCRIPT

  if command -v osascript &>/dev/null; then
    osascript -e "tell application \"Terminal\" to do script \"${LAUNCHER}\""
  else
    # Windows: write a .bat launcher to avoid argument-splitting issues with wt.exe
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
  echo "  Log: ${LOG_FILE}"

elif [ "$MODE" = "remote-control" ]; then
  cat > "$LAUNCHER" <<SCRIPT
#!/bin/bash
cd ${WORKTREE_PATH}
echo "=== Session started: \$(date) ===" >> ${LOG_FILE}
echo "=== Issue: #${ISSUE_NUM} | Skill: ${SKILL} | Mode: remote-control | Worktree: ${WORKTREE_PATH} ===" >> ${LOG_FILE}
${BUILD_ARGV}
CLAUDE_ARGV+=(remote-control --name '${SESSION_NAME}' --spawn same-dir)
CMD=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CLAUDE_ARGV[@]}")
CMD="\${CMD# }"
if [ "\$(uname -s)" = "Darwin" ]; then
  exec script -a ${LOG_FILE} bash -c "\$CMD"
else
  # printf %q emits \$'...' ANSI-C quoting, so force script to use bash (not dash)
  SHELL=/bin/bash exec script -a ${LOG_FILE} -c "\$CMD"
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
  echo "  Log: ${LOG_FILE}"
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
echo "=== Session started: \$(date) ===" >> ${LOG_FILE}
echo "=== Issue: #${ISSUE_NUM} | Skill: ${SKILL} | Mode: tmux | Worktree: ${WORKTREE_PATH} ===" >> ${LOG_FILE}
${BUILD_ARGV}
CLAUDE_ARGV+=(-p '/pipeline:${SKILL} ${ISSUE_NUM}')
INNER=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CLAUDE_ARGV[@]}")
INNER="\${INNER# }"
# -p (print mode): Claude processes the task then exits (no interactive prompt).
# timeout safety net: 90 min with 30s grace before SIGKILL.
CMD="timeout --foreground --signal=TERM --kill-after=30 5400 \$INNER"
if [ "\$(uname -s)" = "Darwin" ]; then
  exec script -a ${LOG_FILE} bash -c "\$CMD"
else
  # printf %q emits \$'...' ANSI-C quoting, so force script to use bash (not dash)
  SHELL=/bin/bash exec script -a ${LOG_FILE} -c "\$CMD"
fi
SCRIPT

  tmux new-window -t "${PIPELINE_TMUX_SESSION:-dev}" -n "$TMUX_WINDOW" "$LAUNCHER"
  echo "Launched tmux session for issue #${ISSUE_NUM}"
  echo "  tmux window: ${PIPELINE_TMUX_SESSION:-dev}:${TMUX_WINDOW}"
  echo "  Log: ${LOG_FILE}"

else
  rm -f "$LAUNCHER"
  echo "ERROR: Unknown mode '$MODE'. Use: terminal, tmux, or remote-control"
  exit 1
fi
