#!/bin/bash
set -euo pipefail

# review-audits.sh — on-demand investigation of pipeline run audits.
#
# Reads raw substrate (runs.log, tool-use.log, subagents.log, git, gh) and
# computes signals on the fly. No derived JSON is maintained.
#
# Usage: bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-audits.sh [flags]
#   --last N        Limit to last N rows of runs.log (applied after other filters).
#   --path A|B|C    Filter to rows where path=X.
#   --deviations    Filter to rows where deviation count > 0.
#   --issue N       Filter to rows where issue=N; switches output to detail view.
#   --since DATE    ISO YYYY-MM-DD; only rows with timestamp >= DATE.
#
# Multiple filters are AND-combined. Zero flags = summarize everything.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/pipeline.config" ] && source "${REPO_ROOT}/pipeline.config"
# shellcheck disable=SC1091
_logging_helper="$(cd "$(dirname "$0")" && pwd)/_logging.sh"
[ -f "$_logging_helper" ] && source "$_logging_helper"
command -v pipeline_logging_enabled >/dev/null 2>&1 || pipeline_logging_enabled() { [ "${PIPELINE_LOGS_ENABLED:-false}" = "true" ]; }

# Resolve CLAUDE_PLUGIN_ROOT for subshells that do not inherit it from Claude
# Code. Idempotent: the shim returns early when the env var is already set.
# shellcheck disable=SC1091
[ -f "$(dirname "$0")/_resolve-plugin-root.sh" ] && \
  source "$(dirname "$0")/_resolve-plugin-root.sh" 2>/dev/null || true

RUNS_LOG="${REPO_ROOT}/.claude/logs/runs.log"
# tool-use.log, subagents.log, and the subagents/ dir are per-worktree:
# spawn-claude.sh launches the CLI with cwd=<worktree>, so CLAUDE_PROJECT_DIR
# resolves to the worktree and both log-tool-use.sh and log_subagent.py write
# under <worktree>/.claude/logs/. Per-run paths are derived from the
# worktree=<path> column in runs.log via worktree_tool_log /
# worktree_subagents_log / worktree_subagents_dir helpers below.
TDD_IMPLEMENTER_MARKER="${CLAUDE_PLUGIN_ROOT:-.}/agents/tdd-implementer.md"

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [flags]
  --last N
  --path A|B|C
  --deviations
  --issue N
  --since YYYY-MM-DD
EOF
}

# -------------------- argv parsing --------------------
FLAG_LAST=""
FLAG_PATH=""
FLAG_DEVIATIONS=0
FLAG_ISSUE=""
FLAG_SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --last)
      [ -z "${2:-}" ] && { usage; exit 2; }
      FLAG_LAST="$2"; shift 2 ;;
    --path)
      [ -z "${2:-}" ] && { usage; exit 2; }
      FLAG_PATH="$2"; shift 2 ;;
    --deviations)
      FLAG_DEVIATIONS=1; shift ;;
    --issue)
      [ -z "${2:-}" ] && { usage; exit 2; }
      FLAG_ISSUE="$2"; shift 2 ;;
    --since)
      [ -z "${2:-}" ] && { usage; exit 2; }
      FLAG_SINCE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown flag: $1" >&2
      usage; exit 2 ;;
  esac
done

# -------------------- argv validation --------------------
# Catch bad inputs early with a clear error instead of leaving them to crash
# later (e.g. --last foo triggers a bash arithmetic error under `set -e`,
# --path X silently matches nothing, --since garbage may match everything).

if [ -n "$FLAG_LAST" ]; then
  case "$FLAG_LAST" in
    ''|*[!0-9]*)
      echo "Error: --last expects a non-negative integer, got: '$FLAG_LAST'" >&2
      usage; exit 1 ;;
  esac
fi

if [ -n "$FLAG_PATH" ]; then
  case "$FLAG_PATH" in
    A|B|C) : ;;
    *)
      echo "Error: --path expects one of A|B|C, got: '$FLAG_PATH'" >&2
      usage; exit 1 ;;
  esac
fi

if [ -n "$FLAG_SINCE" ]; then
  if ! date -d "$FLAG_SINCE" +%s >/dev/null 2>&1; then
    echo "Error: --since expects a parseable date (e.g. YYYY-MM-DD), got: '$FLAG_SINCE'" >&2
    usage; exit 1
  fi
fi

# -------------------- pre-flight --------------------
if ! pipeline_logging_enabled || [ ! -f "$RUNS_LOG" ] || [ ! -s "$RUNS_LOG" ]; then
  echo "Pipeline logging is disabled. To enable, set PIPELINE_LOGS_ENABLED=true in pipeline.config."
  exit 0
fi

# -------------------- helpers --------------------

# skill_alias <skill>
skill_alias() {
  case "$1" in
    execute-issue-plan)  echo "EXECUTE" ;;
    evaluate-issue-pr)   echo "EVALUATE_PR" ;;
    plan-issue)          echo "PLAN" ;;
    evaluate-issue-plan) echo "EVALUATE_PLAN" ;;
    *) echo "" ;;
  esac
}

# parse_col <line> <col-prefix>
# Extracts the value of the tab-separated column whose value starts with <prefix>=
parse_col() {
  local line="$1" prefix="$2"
  printf '%s' "$line" | awk -F'\t' -v p="$prefix=" '
    { for (i=1; i<=NF; i++) { if (index($i, p)==1) { print substr($i, length(p)+1); exit } } }
  '
}

# Extract issue / path / skill / session / ts / worktree from a runs.log line.
parse_ts()       { printf '%s' "$1" | awk -F'\t' '{print $1}'; }
parse_session()  { parse_col "$1" "session"; }
parse_issue()    { parse_col "$1" "issue"; }
parse_path()     { parse_col "$1" "path"; }
parse_skill()    { parse_col "$1" "skill"; }
parse_worktree() { parse_col "$1" "worktree"; }

# expected_skills <path> <skill>
expected_skills() {
  local p="$1" s="$2" alias
  alias=$(skill_alias "$s")
  [ -z "$alias" ] && { echo ""; return; }
  local var="PIPELINE_PATH_${p}_SKILLS_${alias}"
  echo "${!var:-}"
}

# worktree_tool_log <worktree>  (empty if worktree missing/unavailable)
worktree_tool_log() {
  local wt="$1"
  [ -n "$wt" ] && [ -d "$wt" ] && echo "$wt/.claude/logs/tool-use.log"
}

# worktree_subagents_log <worktree>
worktree_subagents_log() {
  local wt="$1"
  [ -n "$wt" ] && [ -d "$wt" ] && echo "$wt/.claude/logs/subagents.log"
}

# worktree_subagents_dir <worktree>
worktree_subagents_dir() {
  local wt="$1"
  [ -n "$wt" ] && [ -d "$wt" ] && echo "$wt/.claude/logs/subagents"
}

# actual_skills <session> <worktree>  (prints one skill per line, invocation order)
actual_skills() {
  local session="$1" wt="$2"
  local tool_log
  tool_log=$(worktree_tool_log "$wt")
  [ -n "$tool_log" ] && [ -f "$tool_log" ] || return 0
  awk -F'\t' -v s="session=$session" '
    $2=="Skill" && $3==s {
      for (i=4; i<=NF; i++) {
        if (index($i, "skill=")==1) { print substr($i, 7); next }
      }
    }
  ' "$tool_log"
}

# first_tools <session> <worktree>  (first 5 tool names, tab-separated)
first_tools() {
  local session="$1" wt="$2"
  local tool_log
  tool_log=$(worktree_tool_log "$wt")
  [ -n "$tool_log" ] && [ -f "$tool_log" ] || return 0
  awk -F'\t' -v s="session=$session" '$3==s {print $2}' "$tool_log" | head -5 | paste -sd '  ' -
}

# deviations <path> <skill> <session> <worktree>
# Prints 0 or more deviation descriptions, one per line. Count = line count.
# If the worktree has been cleaned (or was never set), the session's tool-use
# log is unreachable — in that case return nothing rather than fabricating
# "no tool call" deviations for every expected skill.
deviations_for() {
  local p="$1" s="$2" session="$3" wt="$4"
  local expected
  expected=$(expected_skills "$p" "$s")
  [ -z "$expected" ] && return 0

  # No accessible tool-use.log → can't distinguish "agent skipped skill" from
  # "log was cleaned up". Return empty; the cleaned-row annotation is surfaced
  # separately by the detail/table view.
  local tool_log
  tool_log=$(worktree_tool_log "$wt")
  [ -n "$tool_log" ] && [ -f "$tool_log" ] || return 0

  # Load expected into array
  local -a exp_arr=()
  for sk in $expected; do exp_arr+=("$sk"); done
  local n=${#exp_arr[@]}

  # Load actual into array
  local -a act_arr=()
  local a
  while IFS= read -r a; do
    [ -n "$a" ] && act_arr+=("$a")
  done < <(actual_skills "$session" "$wt")
  local m=${#act_arr[@]}

  local i
  for ((i=0; i<n; i++)); do
    if [ "$i" -ge "$m" ]; then
      echo "skill ${exp_arr[i]} expected at pos $((i+1)), no tool call"
    elif [ "${act_arr[i]}" != "${exp_arr[i]}" ]; then
      echo "skill ${exp_arr[i]} expected at pos $((i+1)), saw ${act_arr[i]}"
    fi
  done
}

# subagent_dispatches <session> <worktree>
# Prints "type\tdesc" lines for each subagent dispatch.
subagent_dispatches() {
  local session="$1" wt="$2"
  local subagents_log subagents_dir
  subagents_log=$(worktree_subagents_log "$wt")
  subagents_dir=$(worktree_subagents_dir "$wt")
  [ -n "$subagents_log" ] && [ -f "$subagents_log" ] || return 0
  awk -F'\t' -v s="$session" '$2==s {print $7}' "$subagents_log" | \
    while IFS= read -r fn; do
      [ -z "$fn" ] && continue
      local p="$subagents_dir/$fn"
      if [ -f "$p" ] && command -v jq >/dev/null 2>&1; then
        jq -r '[.subagent_type, .description] | @tsv' "$p" 2>/dev/null || true
      fi
    done
}

# pr_stage <issue>  (safe when gh is unavailable)
pr_stage() {
  local issue="$1"
  local labels
  labels=$(gh issue view "$issue" --repo "${PIPELINE_REPO:-fake/repo}" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
  local stage="(unknown)"
  for s in plan-pending plan-reviewed plan-approved in-progress pr-open merged; do
    if printf '%s\n' "$labels" | grep -qx "$s"; then stage="$s"; fi
  done
  echo "$stage"
}

# tdd_for <path> <issue>
# Returns "pass" / "fail(N)" / "unknown"
# Very conservative — this is a bash-only heuristic, not a formal proof.
#
# TODO(#329-follow-up): commit-walk logic deferred per approved plan.
# Currently returns "unknown" for all TDD signals. Implement this to
# compare test-file commits to impl-file commits in the PR's branch range
# (resolve the headRefName via `gh pr list --search "linked:issue-$issue"`,
# then walk `git log base..head` classifying each commit as test-only vs
# impl-touching and verify test-only commits precede impl commits).
tdd_for() {
  local p="$1" issue="$2"
  [ "$p" = "A" ] && { echo "unknown"; return; }
  # Degrade gracefully when git / gh are not available or repo is empty.
  if ! command -v gh >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    echo "unknown"; return
  fi
  # NOTE: the future implementation will resolve the PR head branch here via
  #   branch=$(gh pr list --repo "${PIPELINE_REPO:-fake/repo}" \
  #     --search "linked:issue-$issue" --state all \
  #     --json headRefName --jq '.[0].headRefName // empty' 2>/dev/null || true)
  # and then walk `git log $PIPELINE_BASE_BRANCH..$branch`. Omitted for now
  # because the stub returns "unknown" unconditionally — keeping the call
  # live would be dead code that nonetheless hits the GitHub API on every
  # audit run.
  echo "unknown"
}

# tdd_implementer_label <count>
# For PATH C rows, label the subagent-dispatch count.
tdd_implementer_label() {
  local count="$1"
  if [ "$count" -gt 0 ]; then
    echo "tdd-implementer: $count dispatches"
  elif [ -f "$TDD_IMPLEMENTER_MARKER" ]; then
    echo "tdd-implementer: MISSING (enforcement required since #327)"
  else
    echo "tdd-implementer: not dispatched (enforcement deferred to #327)"
  fi
}

# -------------------- filter rows --------------------
# Stream runs.log, apply filters, collect matching rows into an array.
FILTERED=()
while IFS= read -r line; do
  [ -z "$line" ] && continue

  ts=$(parse_ts "$line")
  p=$(parse_path "$line")
  i=$(parse_issue "$line")

  # Filters
  if [ -n "$FLAG_PATH" ] && [ "$p" != "$FLAG_PATH" ]; then continue; fi
  if [ -n "$FLAG_ISSUE" ] && [ "$i" != "$FLAG_ISSUE" ]; then continue; fi
  if [ -n "$FLAG_SINCE" ]; then
    # Compare ISO timestamps as strings (YYYY-MM-DD prefix is sort-safe).
    if [ "$(printf '%s' "$ts" | cut -c1-10)" \< "$FLAG_SINCE" ]; then continue; fi
  fi

  FILTERED+=("$line")
done < "$RUNS_LOG"

# Apply --last to the tail of the filtered list.
if [ -n "$FLAG_LAST" ] && [ "${#FILTERED[@]}" -gt 0 ]; then
  keep=$FLAG_LAST
  total=${#FILTERED[@]}
  if [ "$keep" -lt "$total" ]; then
    start=$((total - keep))
    TMP=()
    for ((k=start; k<total; k++)); do TMP+=("${FILTERED[k]}"); done
    FILTERED=("${TMP[@]}")
  fi
fi

# --deviations is applied after signal computation below.

# -------------------- DETAIL VIEW (--issue) --------------------
if [ -n "$FLAG_ISSUE" ]; then
  if [ ${#FILTERED[@]} -eq 0 ]; then
    echo "Issue #$FLAG_ISSUE has no logged runs."
    exit 0
  fi
  first=1
  for line in "${FILTERED[@]}"; do
    if [ "$first" = 0 ]; then echo ""; fi
    first=0

    ts=$(parse_ts "$line")
    session=$(parse_session "$line")
    p=$(parse_path "$line")
    s=$(parse_skill "$line")
    wt=$(parse_worktree "$line")

    # Flag cleaned-up / missing worktrees so the reader doesn't misread
    # a zero-signals row as "everything was fine".
    wt_annotation=""
    if [ -z "$wt" ]; then
      wt_annotation=" (no worktree recorded)"
    elif [ ! -d "$wt" ]; then
      wt_annotation=" (cleaned — per-run signals unavailable)"
    fi

    echo "DETAIL — issue #$FLAG_ISSUE"
    echo "================================================================="
    echo "Session:       $session"
    echo "Timestamp:     $ts"
    echo "Path:          $p"
    echo "Skill:         $s"
    echo "Worktree:      ${wt:-<unset>}${wt_annotation}"
    echo "Tool seq (5):  $(first_tools "$session" "$wt")"

    expected=$(expected_skills "$p" "$s")
    echo "Expected:      ${expected:-<none for this path/skill>}"

    act=""
    while IFS= read -r a; do
      [ -z "$a" ] && continue
      [ -z "$act" ] && act="$a" || act="${act}\n               $a"
    done < <(actual_skills "$session" "$wt")
    echo -e "Actual:        ${act:-<none>}"

    devs=$(deviations_for "$p" "$s" "$session" "$wt")
    if [ -z "$devs" ]; then
      echo "Deviations:    none"
    else
      local_first=1
      while IFS= read -r d; do
        [ -z "$d" ] && continue
        if [ "$local_first" = 1 ]; then
          echo "Deviations:    $d"
          local_first=0
        else
          echo "               $d"
        fi
      done <<< "$devs"
    fi

    sa_count=0
    sa_lines=""
    while IFS= read -r ln; do
      [ -z "$ln" ] && continue
      sa_count=$((sa_count + 1))
      [ -z "$sa_lines" ] && sa_lines="$ln" || sa_lines="$(printf '%s\n%s' "$sa_lines" "$ln")"
    done < <(subagent_dispatches "$session" "$wt")
    if [ "$sa_count" = 0 ]; then
      echo "Subagents (0): none"
    else
      echo "Subagents ($sa_count):"
      while IFS=$'\t' read -r st desc; do
        echo "               ${st:-?} — \"${desc:-}\""
      done <<< "$sa_lines"
    fi

    if [ "$p" = "C" ]; then
      c_count=0
      while IFS=$'\t' read -r st _; do
        [ "${st##*:}" = "tdd-implementer" ] && c_count=$((c_count + 1))
      done < <(subagent_dispatches "$session" "$wt")
      echo "PATH C check:  $(tdd_implementer_label "$c_count")"
    fi
    echo "TDD pattern:   $(tdd_for "$p" "$FLAG_ISSUE")"
    echo "PR stage:      $(pr_stage "$FLAG_ISSUE")"
    echo "================================================================="
  done
  exit 0
fi

# -------------------- TABLE VIEW --------------------

# Compute signals per row, optionally filtering by --deviations.
ROW_TS=()
ROW_ISSUE=()
ROW_PATH=()
ROW_SKILL=()
ROW_SUBC=()
ROW_DEVC=()
ROW_TDD=()
ROW_STAGE=()
ROW_CLEANED=()
# Per-path deviation reason frequency map — key encoding: "<path>|<reason>".
# Used to compute the "Most-common deviation" summary column per Design-decision 6.
declare -A DEV_REASON_COUNT
CLEANED_COUNT=0
if [ "${#FILTERED[@]}" -gt 0 ]; then
for line in "${FILTERED[@]}"; do
  ts=$(parse_ts "$line")
  i=$(parse_issue "$line")
  p=$(parse_path "$line")
  s=$(parse_skill "$line")
  session=$(parse_session "$line")
  wt=$(parse_worktree "$line")

  # Worktree may have been cleaned up by cleanup-worktree.sh, or may never
  # have been recorded (legacy runs.log rows). In either case per-run
  # signals (skills, subagents, deviations) are unavailable.
  cleaned=0
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    cleaned=1
  fi

  # subagent dispatch count
  subc=0
  while IFS= read -r _; do subc=$((subc + 1)); done < <(subagent_dispatches "$session" "$wt")

  # deviation count + frequency accumulation
  devc=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    devc=$((devc + 1))
    key="${p}|${d}"
    DEV_REASON_COUNT[$key]=$(( ${DEV_REASON_COUNT[$key]:-0} + 1 ))
  done < <(deviations_for "$p" "$s" "$session" "$wt")

  if [ "$FLAG_DEVIATIONS" = "1" ] && [ "$devc" = "0" ]; then continue; fi

  ROW_TS+=("$ts")
  ROW_ISSUE+=("$i")
  ROW_PATH+=("$p")
  ROW_SKILL+=("$s")
  ROW_SUBC+=("$subc")
  ROW_DEVC+=("$devc")
  ROW_TDD+=("$(tdd_for "$p" "$i")")
  ROW_STAGE+=("$(pr_stage "$i")")
  ROW_CLEANED+=("$cleaned")
  if [ "$cleaned" = "1" ]; then CLEANED_COUNT=$((CLEANED_COUNT + 1)); fi
done
fi

# most_common_dev_reason <path>
# Prints "<reason> (<n>x)" for the highest-count reason on <path>, or "—" if
# no deviations exist for that path.
most_common_dev_reason() {
  local p="$1" best_reason="" best_count=0 key count reason
  for key in "${!DEV_REASON_COUNT[@]}"; do
    case "$key" in
      "${p}|"*) : ;;
      *) continue ;;
    esac
    count=${DEV_REASON_COUNT[$key]}
    reason="${key#${p}|}"
    if [ "$count" -gt "$best_count" ]; then
      best_count=$count
      best_reason=$reason
    fi
  done
  if [ "$best_count" = "0" ]; then
    echo "—"
  else
    echo "${best_reason} (${best_count}x)"
  fi
}

N=${#ROW_TS[@]}

if [ "$N" = "0" ]; then
  echo "No runs match the filter. (RUNS_LOG: $RUNS_LOG)"
  exit 0
fi

DATE_TAG="$(date -u +%Y-%m-%d)"
echo "AUDIT — $DATE_TAG ($N run$([ "$N" = "1" ] || echo "s"))"
echo "================================================================================================================"
printf ' %-21s %-6s %-5s %-24s %-10s %-11s %-12s %s\n' \
  "Timestamp" "Issue" "Path" "Skill" "Subagents" "Deviations" "TDD" "Stage"
echo "----------------------------------------------------------------------------------------------------------------"
for idx in $(seq 0 $((N-1))); do
  if [ "${ROW_CLEANED[idx]}" = "1" ]; then
    # Per-run signals are unreachable — render em-dashes rather than 0, and
    # append a marker to the Stage column so the reader sees the row isn't
    # just "passed audit with 0 deviations".
    stage_col="${ROW_STAGE[idx]} (worktree-cleaned)"
    printf ' %-21s %-6s %-5s %-24s %-10s %-11s %-12s %s\n' \
      "${ROW_TS[idx]}" "#${ROW_ISSUE[idx]}" "${ROW_PATH[idx]}" \
      "${ROW_SKILL[idx]:0:24}" "—" "—" \
      "${ROW_TDD[idx]:0:12}" "$stage_col"
  else
    printf ' %-21s %-6s %-5s %-24s %-10s %-11s %-12s %s\n' \
      "${ROW_TS[idx]}" "#${ROW_ISSUE[idx]}" "${ROW_PATH[idx]}" \
      "${ROW_SKILL[idx]:0:24}" "${ROW_SUBC[idx]}" "${ROW_DEVC[idx]}" \
      "${ROW_TDD[idx]:0:12}" "${ROW_STAGE[idx]}"
  fi
done
echo "================================================================================================================"
if [ "$CLEANED_COUNT" -gt 0 ]; then
  echo "Note: $CLEANED_COUNT row(s) had no/unavailable worktree; per-run signals are unavailable."
fi
echo ""

# Summary grouped by path.
declare -A S_RUNS S_DEVS
for idx in $(seq 0 $((N-1))); do
  p="${ROW_PATH[idx]}"
  S_RUNS[$p]=$(( ${S_RUNS[$p]:-0} + 1 ))
  S_DEVS[$p]=$(( ${S_DEVS[$p]:-0} + ROW_DEVC[idx] ))
done

echo "SUMMARY"
echo "======================================================================="
printf ' %-5s %-5s %-11s %s\n' "Path" "Runs" "Deviations" "Most-common deviation"
echo "-----------------------------------------------------------------------"
for p in A B C; do
  runs=${S_RUNS[$p]:-0}
  devs=${S_DEVS[$p]:-0}
  mcd=$(most_common_dev_reason "$p")
  printf ' %-5s %-5s %-11s %s\n' "$p" "$runs" "$devs" "$mcd"
done
echo "======================================================================="
