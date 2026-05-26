#!/bin/bash
set -euo pipefail

# Run from the consumer repo root (so `$(pwd)/pipeline.config` resolves), or
# export PIPELINE_PROJECT_ROOT to override the lookup directory.
source "${PIPELINE_PROJECT_ROOT:-$(pwd)}/pipeline.config"

# Observability logging helper: defines pipeline_logging_enabled() which
# returns rc=0 only when PIPELINE_LOGS_ENABLED=true (strict lowercase).
# Used to gate dogfood-only writes under .claude/logs/. Fall back to an
# inline definition when the helper is missing (e.g. partial install or
# tests copying spawn-claude.sh in isolation) so we never hard-fail.
_spawn_claude_dir="$(dirname "${BASH_SOURCE[0]}")"
if [ -f "${_spawn_claude_dir}/_logging.sh" ]; then
  source "${_spawn_claude_dir}/_logging.sh"
else
  pipeline_logging_enabled() { [ "${PIPELINE_LOGS_ENABLED:-false}" = "true" ]; }
fi

# Self-resolve CLAUDE_PLUGIN_ROOT when callers don't export it (e.g. direct
# operator invocation from the consumer project root). Idempotent; no-op
# when CLAUDE_PLUGIN_ROOT is already set. The shim's resolution is the
# single source of truth that classify_issue() in run-queue.sh and the
# fail-closed re-classification block below both rely on for the
# ${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh path (#325).
if [ -f "${_spawn_claude_dir}/_resolve-plugin-root.sh" ]; then
  # shellcheck disable=SC1091
  source "${_spawn_claude_dir}/_resolve-plugin-root.sh"
fi

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
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/issue-${ISSUE_NUM}-${TIMESTAMP}.log"
if pipeline_logging_enabled; then
  mkdir -p "$LOG_DIR"
fi

if [ ! -d "$WORKTREE_PATH" ]; then
  echo "ERROR: Worktree not found at $WORKTREE_PATH"
  exit 1
fi

# --- Build --append-system-prompt payload: label-driven 3-path selection ---
#
# spawn-claude.sh reads the issue's GitHub labels and picks one of four
# execution paths:
#   docs-only  -> PATH A (trivial; verification-only, no TDD gate)
#   quick-fix  -> PATH D (lightweight inline TDD; single red-green-refactor)
#   multi-task -> PATH C (SDD wiring: one implementer subagent per task)
#   else       -> PATH B (standard; TDD mandatory)
# Precedence on label collision is A > D > C > B (A is narrowest; D is a
# lightweight TDD path that beats the multi-task SDD wiring; C beats default).
# Any collision (two or more of docs-only/quick-fix/multi-task) emits a stderr
# warning that names the chosen letter and the colliding labels.
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
    HAS_QUICK=0
    HAS_MULTI=0
    HAS_NEEDS_BROWSER=0
    while IFS= read -r lbl; do
      [ "$lbl" = "docs-only" ] && HAS_DOCS=1
      [ "$lbl" = "quick-fix" ] && HAS_QUICK=1
      [ "$lbl" = "multi-task" ] && HAS_MULTI=1
      [ "$lbl" = "needs-browser" ] && HAS_NEEDS_BROWSER=1
    done <<< "$LABELS"
    # Apply precedence A > D > C > B.
    if [ "$HAS_DOCS" = "1" ]; then
      PATH_LETTER="A"
    elif [ "$HAS_QUICK" = "1" ]; then
      PATH_LETTER="D"
    elif [ "$HAS_MULTI" = "1" ]; then
      PATH_LETTER="C"
    fi
    # Collision warning: two or more of docs-only/quick-fix/multi-task set.
    _collision_count=$((HAS_DOCS + HAS_QUICK + HAS_MULTI))
    if [ "$_collision_count" -ge 2 ]; then
      _collision_labels=""
      [ "$HAS_DOCS" = "1" ] && _collision_labels="${_collision_labels:+$_collision_labels, }docs-only"
      [ "$HAS_QUICK" = "1" ] && _collision_labels="${_collision_labels:+$_collision_labels, }quick-fix"
      [ "$HAS_MULTI" = "1" ] && _collision_labels="${_collision_labels:+$_collision_labels, }multi-task"
      # Preserve the legacy "both docs-only and multi-task" phrasing for the
      # pure docs+multi case so existing tests / log greppers still match.
      if [ "$HAS_DOCS" = "1" ] && [ "$HAS_MULTI" = "1" ] && [ "$HAS_QUICK" = "0" ]; then
        echo "WARNING: issue #$ISSUE_NUM has both docs-only and multi-task labels; picking PATH A" >&2
      else
        echo "WARNING: issue #$ISSUE_NUM has colliding path labels (${_collision_labels}); picking PATH $PATH_LETTER" >&2
      fi
    fi
  else
    echo "[spawn-claude] WARN: gh issue view failed for issue #$ISSUE_NUM, defaulting to PATH B" >&2
  fi
fi

# --- Label-gated MCP attachment (issue #347) ---
# Spawned per-issue agents default to ZERO MCP servers. Opt-in by labelling
# the issue `needs-browser` — the agent then inherits the project `.mcp.json`
# (current behaviour). The orchestrator session (which sources `.mcp.json`
# directly via the working directory) is unaffected by this gating.
#
# Fail-safe: when `gh issue view` failed above, HAS_NEEDS_BROWSER stays 0
# (or unset for bare/unknown-skill spawns) and we default to the empty-MCP
# path. A transient gh outage MUST NOT silently regress to leaking Playwright
# into every spawned agent. EMPTY_MCP_FILE is initialised here (single
# definition point) so cleanup_temp_files and the dry-run dump can reference
# it under `set -u` regardless of which branch is taken.
EMPTY_MCP_FILE=""
MCP_EXTRA_ARGV=()
if [ "${HAS_NEEDS_BROWSER:-0}" = "0" ]; then
  EMPTY_MCP_FILE=$(mktemp /tmp/claude-mcp-empty-XXXXXX.json)
  printf '%s\n' '{"mcpServers": {}}' > "$EMPTY_MCP_FILE"
  MCP_EXTRA_ARGV=(--mcp-config "$EMPTY_MCP_FILE" --strict-mcp-config)
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
if pipeline_logging_enabled; then
  mkdir -p "$(dirname "$RUNS_LOG")"
  printf '%s\tsession=%s\tissue=%s\tpath=%s\tskill=%s\tworktree=%s\n' \
    "$RUNS_TS" "$GENERATED_SESSION_ID" "$ISSUE_NUM" "$PATH_LETTER" "$SKILL" "$WORKTREE_PATH" \
    >> "$RUNS_LOG"
fi

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
  [ -n "$EMPTY_MCP_FILE" ] && files+=("$EMPTY_MCP_FILE")
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

# --- Inline browser-eval dispatch gate (issue #517) ---
# When --container-mode=<name> is set AND PIPELINE_EVAL_ISOLATION != container,
# the consumer has opted into the inline Agent dispatch path: the classifier's
# container-mode token is reinterpreted as a *browser-eval surface* hint, not
# a docker-compose dispatch directive. spawn-claude exports INLINE_BROWSER_EVAL=1
# so downstream tooling (run-queue.sh launch_agent, the evaluate-issue-pr skill)
# can branch on it, and short-circuits BEFORE building DOCKER_PREFIX, validating
# the container allowlist, or running the preflight.
#
# Precondition: the host must expose a Playwright MCP entry in $REPO_ROOT/.mcp.json
# (probed with `jq -e .mcpServers.playwright`). If the entry is missing, exit 6
# with a loud refusal — the inline path needs host Playwright to drive the
# browser; the operator's remediation is to install Playwright MCP or pin the
# legacy container path via PIPELINE_EVAL_ISOLATION=container.
#
# Validation: PIPELINE_EVAL_ISOLATION=container is only honored when the
# --container-mode value also resolves under PIPELINE_EVAL_CONTAINERS; otherwise
# control falls through to the existing exit-4 path emitted by the container
# allowlist block below.
INLINE_BROWSER_EVAL=0
if [ -n "$CONTAINER_MODE" ] && [ "${PIPELINE_EVAL_ISOLATION:-}" != "container" ]; then
  # Host-Playwright MCP probe (orchestrator project root). Fail-closed: if jq
  # is missing or the file lacks a .mcpServers.playwright key, exit 6.
  _mcp_file="${REPO_ROOT}/.mcp.json"
  _mcp_ok=0
  if command -v jq >/dev/null 2>&1 && [ -f "$_mcp_file" ]; then
    if jq -e .mcpServers.playwright "$_mcp_file" >/dev/null 2>&1; then
      _mcp_ok=1
    fi
  fi
  if [ "$_mcp_ok" -ne 1 ]; then
    echo "[spawn-claude] ERROR: PR ${ISSUE_NUM} requires browser eval but host Playwright MCP not detected. Install playwright MCP or set PIPELINE_EVAL_ISOLATION=container." >&2
    exit 6
  fi
  INLINE_BROWSER_EVAL=1
  export INLINE_BROWSER_EVAL
  echo "[spawn-claude] inline browser-eval dispatch for issue #$ISSUE_NUM (CONTAINER_MODE=$CONTAINER_MODE, PIPELINE_EVAL_ISOLATION=${PIPELINE_EVAL_ISOLATION:-})" >&2
fi

# --- Container-mode dispatch (issue #218) ---
# When --container-mode=<name> is set, validate the name against
# PIPELINE_EVAL_CONTAINERS, run the optional preflight, and build a
# `docker compose run --rm ... <service>` prefix that wraps the `claude`
# launch invocation. The prefix is exported through BUILD_ARGV as the
# LAUNCH_CMD bash array, which each launcher mode uses in place of the
# bare `claude` executable when emitting the final CMD.
#
# When INLINE_BROWSER_EVAL=1 (issue #517), this whole block is skipped:
# the allowlist check, the #238 enforcement re-classification, and the
# DOCKER_PREFIX assembly all live behind the `if [ "$INLINE_BROWSER_EVAL" != "1" ]`
# guard so the dry-run dump (and the production launcher) never see a
# docker prefix on the inline path.
DOCKER_PREFIX=()
# --- container-mode skill allowlist (issue #321) ---
# PIPELINE_CONTAINER_SKILLS is a space-separated list of skill names that
# may be dispatched via --container-mode=<name>. Default (when the var is
# UNSET) is "evaluate-issue-pr" — preserves the #218 behavior so existing
# consumers see zero behavior change. EMPTY string ("") is distinct from
# unset: it disables container dispatch for ALL skills. Consumers opt
# additional skills in by listing them in pipeline.config — see
# pipeline.config.example.
#
# Use the ${VAR-default} expansion (NO colon) so empty stays empty.
# ${VAR:-default} would silently rebind empty -> default and break the
# operator's intent to disable.
if [ -n "$CONTAINER_MODE" ] && [ "$INLINE_BROWSER_EVAL" != "1" ]; then
  _container_skills_allowlist="${PIPELINE_CONTAINER_SKILLS-evaluate-issue-pr}"
  # empty allowlist == disable; do not "simplify" — empty-line grep gives the correct rejection.
  if ! printf '%s\n' $_container_skills_allowlist | tr ' ' '\n' | grep -qx "$SKILL"; then
    # --- label-aware container-mode permit for execute-issue-plan (issue #368) ---
    # Do NOT widen the static allowlist; instead grant a per-invocation permit
    # when the issue carries the needs-browser label. This lets a planned
    # browser-dependent execution run in the eval container without opening the
    # gate to every skill. Query labels with the same fail-closed idiom used at
    # line ~127 (if VAR="$(... 2>/dev/null)"; then ... else <reject> fi) so a
    # non-zero gh routes to the reject branch instead of aborting under set -e.
    # gh-failure and unset-ISSUE_NUM both FAIL CLOSED (keep the rejection).
    if [ "$SKILL" = "execute-issue-plan" ] && [ -n "$CONTAINER_MODE" ] && [ -n "$ISSUE_NUM" ]; then
      if _nb_labels="$(gh issue view "$ISSUE_NUM" --repo "$PIPELINE_REPO" --json labels --jq '.labels[].name' 2>/dev/null)"; then
        if printf '%s\n' "$_nb_labels" | grep -qx "needs-browser"; then
          echo "[spawn-claude] container-mode permitted for execute-issue-plan via needs-browser label" >&2
          # permit: skip the rejection (do NOT exit 4)
        else
          echo "[spawn-claude] ERROR: container-mode rejected: skill '$SKILL' not in PIPELINE_CONTAINER_SKILLS allowlist (current: $_container_skills_allowlist)" >&2
          exit 4
        fi
      else
        # gh failed -> FAIL CLOSED: keep the existing rejection
        echo "[spawn-claude] ERROR: container-mode rejected: skill '$SKILL' not in PIPELINE_CONTAINER_SKILLS allowlist (current: $_container_skills_allowlist)" >&2
        exit 4
      fi
    else
      echo "[spawn-claude] ERROR: container-mode rejected: skill '$SKILL' not in PIPELINE_CONTAINER_SKILLS allowlist (current: $_container_skills_allowlist)" >&2
      exit 4
    fi
  fi
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
# ${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh helper is missing / exits non-zero.
if [ -z "$CONTAINER_MODE" ] \
   && [ "$INLINE_BROWSER_EVAL" != "1" ] \
   && [ "$SKILL" = "evaluate-issue-pr" ] \
   && [ -n "${PIPELINE_EVAL_CLASSIFIER:-}" ]; then
  _classifier_invoke="${CLAUDE_PLUGIN_ROOT:-.}/scripts/eval-classifier-invoke.sh"
  if [ -f "$_classifier_invoke" ]; then
    set +e
    _classifier_out="$(PIPELINE_EVAL_CLASSIFIER="$PIPELINE_EVAL_CLASSIFIER" PIPELINE_PROJECT_ROOT="$REPO_ROOT" PIPELINE_REPO="${PIPELINE_REPO:-}" bash "$_classifier_invoke" "$ISSUE_NUM" 2>/dev/null)"
    _classifier_rc=$?
    set -e
    if [ "$_classifier_rc" -eq 0 ] && \
       printf '%s\n' "$_classifier_out" | grep -q '^--container-mode='; then
      _wanted_mode="$(printf '%s\n' "$_classifier_out" | grep '^--container-mode=' | head -1)"
      echo "[spawn-claude] ERROR: classifier wants container dispatch but --container-mode not passed" >&2
      echo "  classifier emitted: ${_wanted_mode}" >&2
      echo "  Re-run after cd-ing to the project root: cd <project-root> && PIPELINE_PROJECT_ROOT=\"\$PWD\" bash \${CLAUDE_PLUGIN_ROOT:-.}/scripts/eval-classifier-invoke.sh ${ISSUE_NUM} | xargs bash \${CLAUDE_PLUGIN_ROOT:-.}/scripts/spawn-claude.sh --skill evaluate-issue-pr ..." >&2
      exit 5
    fi
  fi
fi
if [ -n "$CONTAINER_MODE" ] && [ "$INLINE_BROWSER_EVAL" != "1" ]; then
  if ! printf '%s\n' ${PIPELINE_EVAL_CONTAINERS:-} | tr ' ' '\n' | grep -qx "$CONTAINER_MODE"; then
    echo "[spawn-claude] ERROR: container-mode '$CONTAINER_MODE' not declared in PIPELINE_EVAL_CONTAINERS" >&2
    exit 4
  fi
  # Source the case-insensitive env-var resolver (#336). UPPERCASE wins,
  # lowercase falls back. Idempotent guard: only source once per process.
  # Fall back to an inline definition when the helper is missing (mirrors
  # the _logging.sh pattern above) so tests that copy spawn-claude.sh in
  # isolation never hard-fail. The fallback body MUST stay identical to
  # scripts/_resolve-container-var.sh.
  if ! declare -f _resolve_container_var >/dev/null 2>&1; then
    _resolver="${CLAUDE_PLUGIN_ROOT:-$_spawn_claude_dir}/scripts/_resolve-container-var.sh"
    [ -f "$_resolver" ] || _resolver="${_spawn_claude_dir}/_resolve-container-var.sh"
    if [ -f "$_resolver" ]; then
      # shellcheck source=/dev/null
      . "$_resolver"
    else
      _resolve_container_var() {
        local mode="$1" suffix="$2"
        local norm_lower norm_upper var_upper var_lower
        norm_lower="$(echo "$mode" | tr '-' '_')"
        norm_upper="$(echo "$norm_lower" | tr '[:lower:]' '[:upper:]')"
        var_upper="PIPELINE_EVAL_CONTAINER_${norm_upper}_${suffix}"
        var_lower="PIPELINE_EVAL_CONTAINER_${norm_lower}_${suffix}"
        printf '%s' "${!var_upper:-${!var_lower:-}}"
      }
    fi
  fi
  norm_mode_upper="$(echo "$CONTAINER_MODE" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
  COMPOSE_FILE="$(_resolve_container_var "$CONTAINER_MODE" COMPOSE_FILE)"
  ENV_FILE="$(_resolve_container_var "$CONTAINER_MODE" ENV_FILE)"
  SERVICE="$(_resolve_container_var "$CONTAINER_MODE" SERVICE)"
  PREFLIGHT="$(_resolve_container_var "$CONTAINER_MODE" PREFLIGHT_CMD)"
  # Error messages name the UPPERCASE form (the recommended/canonical idiom)
  # so new consumers see the canonical name first. Lowercase setups still
  # resolve via the fallback; they only see this name on a missing-var
  # error, in which case they're steered to UPPERCASE.
  compose_var="PIPELINE_EVAL_CONTAINER_${norm_mode_upper}_COMPOSE_FILE"
  svc_var="PIPELINE_EVAL_CONTAINER_${norm_mode_upper}_SERVICE"
  # Resolve a relative ENV_FILE to absolute against WORKTREE_PATH BEFORE
  # DOCKER_PREFIX is assembled. The probe (mock-web-eval/scripts/mock-web-eval-probe-port.sh)
  # writes the env file under PIPELINE_WORKTREE_PATH so concurrent worktrees
  # don't race on a shared file; the reader here must agree. Absolute paths
  # are passed through verbatim. (#269; supersedes the REPO_ROOT base from #257.)
  if [ -n "$ENV_FILE" ] && [[ "$ENV_FILE" != /* ]]; then
    ENV_FILE="$WORKTREE_PATH/$ENV_FILE"
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
# One `CLAUDE_ARGV+=(<tok>)` line per label-gated MCP token (issue #347).
_mcp_argv_lines=""
for tok in ${MCP_EXTRA_ARGV[@]+"${MCP_EXTRA_ARGV[@]}"}; do
  _mcp_argv_lines+="CLAUDE_ARGV+=($(printf '%q' "$tok"))"$'\n'
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
'"$_extra_argv_lines$_mcp_argv_lines"

# Test hook: dump resolved state and exit before launching anything.
if [ "${PIPELINE_SPAWN_DRY_RUN:-}" = "1" ]; then
  echo "PATH_LETTER=$PATH_LETTER"
  echo "GENERATED_SESSION_ID=$GENERATED_SESSION_ID"
  echo "RUNS_LOG=$RUNS_LOG"
  echo "RUNS_LOG_LINE=$(tail -1 "$RUNS_LOG")"
  echo "SYSPROMPT_FILE=$APPEND_PROMPT_FILE"
  echo "EMPTY_MCP_FILE=$EMPTY_MCP_FILE"
  echo "CONTAINER_MODE=$CONTAINER_MODE"
  echo "INLINE_BROWSER_EVAL=$INLINE_BROWSER_EVAL"
  echo "PIPELINE_EVAL_ISOLATION=${PIPELINE_EVAL_ISOLATION:-}"
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

# Precompute the launcher's session-start banner and exec line based on the
# logging gate in the spawning shell. When PIPELINE_LOGS_ENABLED is false, the
# launcher must NOT touch $LOG_FILE (its parent dir was never created at line
# 70-72) and must NOT wrap the claude invocation in `script -a $LOG_FILE`
# (would error out trying to open a file under a missing directory). Bake the
# decision into the heredoc rather than re-sourcing _logging.sh in the launcher.
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
CLAUDE_ARGV+=('/pipeline:${SKILL} ${ISSUE_NUM}')
CMD=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CLAUDE_ARGV[@]}")
CMD="\${CMD# }"
if [ "\$(uname -s)" = "Darwin" ]; then
  ${LAUNCHER_EXEC_DARWIN}
else
  # printf %q emits \$'...' ANSI-C quoting, so force script to use bash (not dash)
  ${LAUNCHER_EXEC_LINUX}
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
  if pipeline_logging_enabled; then echo "  Log: ${LOG_FILE}"; fi

elif [ "$MODE" = "remote-control" ]; then
  cat > "$LAUNCHER" <<SCRIPT
#!/bin/bash
cd ${WORKTREE_PATH}
${LAUNCHER_BANNER_REMOTECTL}
${BUILD_ARGV}
CLAUDE_ARGV+=(remote-control --name '${SESSION_NAME}' --spawn same-dir)
CMD=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CLAUDE_ARGV[@]}")
CMD="\${CMD# }"
if [ "\$(uname -s)" = "Darwin" ]; then
  ${LAUNCHER_EXEC_DARWIN}
else
  # printf %q emits \$'...' ANSI-C quoting, so force script to use bash (not dash)
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
CLAUDE_ARGV+=(-p '/pipeline:${SKILL} ${ISSUE_NUM}')
INNER=\$(printf ' %q' "\${LAUNCH_CMD[@]}" "\${CLAUDE_ARGV[@]}")
INNER="\${INNER# }"
# -p (print mode): Claude processes the task then exits (no interactive prompt).
# timeout safety net: 90 min with 30s grace before SIGKILL.
CMD="timeout --foreground --signal=TERM --kill-after=30 5400 \$INNER"
if [ "\$(uname -s)" = "Darwin" ]; then
  ${LAUNCHER_EXEC_DARWIN}
else
  # printf %q emits \$'...' ANSI-C quoting, so force script to use bash (not dash)
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
