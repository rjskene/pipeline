#!/bin/bash
# render-status-table.sh — deterministic, hermetic pipeline status table
# renderer.
#
# Usage:
#   render-status-table.sh --issues <issues.json> \
#                          [--trackers <trackers.json>] \
#                          [--release-prs <release-prs.txt>] \
#                          [--today YYYY-MM-DD]
#
# Inputs are FILES (no live `gh` calls). All three input shapes are produced
# upstream by `/pipeline:run` step 0–1:
#   issues.json     — verbatim `gh issue list --json number,title,labels,body,updatedAt`
#   trackers.json   — JSON object {"<num>": "<body string>", ...} per tracker
#   release-prs.txt — one line per release PR in the format
#                       pr=<num> ci=<pass|fail|pending> title=<title>
#                     (already emitted by scripts/list-release-prs.sh).
#
# Writes the canonical status table to stdout. Exit codes:
#   0 — success (incl. empty input that yields a minimally-headered table)
#   2 — missing/unparseable input or usage error
#
# Sources pipeline.config when present so label-name knobs
# (PIPELINE_BASE_BRANCH, PIPELINE_LABELS_*) resolve correctly.

set -uo pipefail

# ----- argv parsing ---------------------------------------------------

usage() {
  cat >&2 <<USAGE
usage: render-status-table.sh --issues <issues.json>
                              [--trackers <trackers.json>]
                              [--release-prs <release-prs.txt>]
                              [--today YYYY-MM-DD]
USAGE
}

ISSUES_FILE=""
TRACKERS_FILE=""
RELEASE_PRS_FILE=""
TODAY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --issues)      ISSUES_FILE="${2:-}"; shift 2 ;;
    --trackers)    TRACKERS_FILE="${2:-}"; shift 2 ;;
    --release-prs) RELEASE_PRS_FILE="${2:-}"; shift 2 ;;
    --today)       TODAY="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "render-status-table.sh: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$ISSUES_FILE" ]; then
  echo "render-status-table.sh: --issues is required" >&2
  usage
  exit 2
fi

if [ ! -f "$ISSUES_FILE" ]; then
  echo "render-status-table.sh: --issues file not found: $ISSUES_FILE" >&2
  exit 2
fi

if [ -n "$TRACKERS_FILE" ] && [ ! -f "$TRACKERS_FILE" ]; then
  echo "render-status-table.sh: --trackers file not found: $TRACKERS_FILE" >&2
  exit 2
fi

if [ -n "$RELEASE_PRS_FILE" ] && [ ! -f "$RELEASE_PRS_FILE" ]; then
  echo "render-status-table.sh: --release-prs file not found: $RELEASE_PRS_FILE" >&2
  exit 2
fi

[ -n "$TODAY" ] || TODAY=$(date -u +%Y-%m-%d)

# ----- pipeline.config sourcing --------------------------------------

# Resolve consumer project root the same way list-release-prs.sh does: prefer
# explicit env, fall back to cwd. We don't fail if pipeline.config is absent —
# the renderer falls back to defaults baked into pipeline.config.example.
_PROJECT_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
if [ -f "$_PROJECT_ROOT/pipeline.config" ]; then
  # shellcheck disable=SC1091
  source "$_PROJECT_ROOT/pipeline.config"
fi

: "${PIPELINE_BASE_BRANCH:=staging}"
: "${PIPELINE_LABELS_EXCLUDED:=excluded}"
: "${PIPELINE_LABELS_LATER:=later}"
: "${PIPELINE_LABELS_HUMAN:=human}"
: "${PIPELINE_LABELS_BRAINSTORM:=brainstorm}"

# ----- per-row metadata projection (issues.json → flat rows) ---------
#
# jq emits one record per issue with the fields the renderer needs:
#   number, title, scope, priority_tier, priority_badge, stage
# Stage label precedence mirrors the prose spec in skills/run/SKILL.md
# (merged > pr-open > in-progress > plan-approved > plan-reviewed >
#  plan-pending > tracker > later > human > brainstorm > ready).
# Scope comes from the conventional-commit `type(scope):` prefix; titles
# without that shape land in the `(none / generic)` bucket.
ROWS_JSON=$(jq -c \
  --arg later     "$PIPELINE_LABELS_LATER" \
  --arg human     "$PIPELINE_LABELS_HUMAN" \
  --arg brainst   "$PIPELINE_LABELS_BRAINSTORM" '
  def labelnames: [.labels[].name];
  def has_label(n): labelnames | any(. == n);
  def priority_tier:
    ([labelnames[] | capture("^priority/P(?<n>[0-3])$").n] | first)
    | if . == null then "9" else . end;
  def priority_badge:
    priority_tier | if . == "9" then "[--]" else "[P\(.)]" end;
  def stage:
    if has_label("merged") then "merged"
    elif has_label("pr-open") then "pr-open"
    elif has_label("in-progress") then "in-progress"
    elif has_label("plan-approved") then "plan-approved"
    elif has_label("plan-reviewed") then "plan-reviewed"
    elif has_label("plan-pending") then "plan-pending"
    elif has_label("tracker") then "tracker"
    elif has_label($later)   then $later
    elif has_label($human)   then $human
    elif has_label($brainst) then $brainst
    else "ready"
    end;
  def scope:
    ([.title
        | capture("^(?<t>feat|fix|chore|refactor|docs|test|perf|build|ci|style|revert|bug|brainstorm)\\((?<s>[^)]+)\\):").s
      ] | first)
    | if . == null then "" else . end;
  [ .[] | {
      number,
      title,
      scope: scope,
      priority_tier: priority_tier,
      priority_badge: priority_badge,
      stage: stage,
      is_tracker: has_label("tracker")
    }
  ]
' "$ISSUES_FILE")

if [ -z "$ROWS_JSON" ]; then
  echo "render-status-table.sh: failed to parse $ISSUES_FILE" >&2
  exit 2
fi

# ----- tracker child extraction --------------------------------------
#
# For each tracker body in --trackers, pipe through the shared parser to
# get its child issue numbers, then intersect with the open-issue set to
# get OPEN children. A child referenced under multiple trackers is
# collected into MULTI_TRACKER_CHILDREN for the WARN line (Task 5).

# Resolve parse-tracker-children.sh — prefer ${CLAUDE_PLUGIN_ROOT} when set
# (consumer install), fall back to the dogfood checkout sibling path.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_CHILDREN="${CLAUDE_PLUGIN_ROOT:-$_SCRIPT_DIR/..}/scripts/parse-tracker-children.sh"
[ -x "$PARSE_CHILDREN" ] || PARSE_CHILDREN="$_SCRIPT_DIR/parse-tracker-children.sh"

declare -A CHILDREN_BY_TRACKER=()
declare -A TRACKER_COUNT_FOR_CHILD=()
declare -A FIRST_TRACKER_FOR_CHILD=()
declare -A SECOND_TRACKER_FOR_CHILD=()
declare -A IS_CHILD=()
MULTI_TRACKER_LINES=()

OPEN_NUMBERS=$(printf '%s' "$ROWS_JSON" | jq -r '.[].number' | sort -u)

if [ -n "$TRACKERS_FILE" ]; then
  # Iterate tracker keys in the JSON map.
  while IFS= read -r tracker_num; do
    [ -n "$tracker_num" ] || continue
    body=$(jq -r --arg k "$tracker_num" '.[$k] // ""' "$TRACKERS_FILE")
    [ -n "$body" ] || continue
    raw_children=$(printf '%s\n' "$body" | bash "$PARSE_CHILDREN" -)
    open_children=""
    for c in $raw_children; do
      if printf '%s\n' "$OPEN_NUMBERS" | grep -qx "$c"; then
        open_children="$open_children $c"
        # Track multi-tracker membership.
        TRACKER_COUNT_FOR_CHILD["$c"]=$(( ${TRACKER_COUNT_FOR_CHILD["$c"]:-0} + 1 ))
        if [ -z "${FIRST_TRACKER_FOR_CHILD["$c"]:-}" ]; then
          FIRST_TRACKER_FOR_CHILD["$c"]="$tracker_num"
        elif [ -z "${SECOND_TRACKER_FOR_CHILD["$c"]:-}" ]; then
          SECOND_TRACKER_FOR_CHILD["$c"]="$tracker_num"
        fi
        IS_CHILD["$c"]=1
      fi
    done
    # shellcheck disable=SC2086
    CHILDREN_BY_TRACKER["$tracker_num"]=$(echo $open_children | tr ' ' '\n' | awk 'NF' | paste -sd ' ' -)
  done < <(jq -r 'keys[]' "$TRACKERS_FILE")
fi

# Build WARN lines (one per duplicated child) — emitted by Task 5.
for c in "${!TRACKER_COUNT_FOR_CHILD[@]}"; do
  if [ "${TRACKER_COUNT_FOR_CHILD[$c]}" -gt 1 ]; then
    MULTI_TRACKER_LINES+=("WARN: #$c listed under multiple trackers: #${FIRST_TRACKER_FOR_CHILD[$c]}, #${SECOND_TRACKER_FOR_CHILD[$c]}")
  fi
done

# Build a JSON array of child numbers (for jq exclusion below).
CHILD_NUMBERS_JSON='[]'
if [ "${#IS_CHILD[@]}" -gt 0 ]; then
  CHILD_NUMBERS_JSON=$(printf '%s\n' "${!IS_CHILD[@]}" \
    | jq -R 'tonumber' | jq -s '.')
fi

# ----- ORPHANS section -----------------------------------------------
#
# Orphans = non-tracker issues NOT referenced as a child under any tracker.
# Bucket alphabetically with (none / generic) last; within a bucket, sort
# by priority tier ("9" = no priority, comes last).
ORPHAN_ROWS_JSON=$(printf '%s' "$ROWS_JSON" \
  | jq -c --argjson children "$CHILD_NUMBERS_JSON" \
      '[.[] | select((.is_tracker | not) and ((.number as $n | $children | index($n)) == null))]')

# Compute bucket names: explicit (alphabetical) scopes + a sentinel for empty
BUCKETS=$(printf '%s' "$ORPHAN_ROWS_JSON" \
  | jq -r '[.[].scope] | unique | .[]' \
  | awk 'NF { print "named:" $0 } !NF { has_empty=1 } END { if (has_empty) print "generic:" }')

# Emit table header
echo "PIPELINE STATUS — $TODAY"
echo "================================================================"

# ----- EPICS section -------------------------------------------------
#
# Tracker rows render with the [Pn] #N — title format (no stage suffix).
# Each open child appears indented 8 spaces with the stage right-padded
# in parens. A tracker whose checklist children are ALL closed collapses
# to a single "(all children closed — pending auto-close)" placeholder.
TRACKER_ROWS_JSON=$(printf '%s' "$ROWS_JSON" | jq -c '[.[] | select(.is_tracker)] | sort_by(.priority_tier, .number)')
TRACKER_COUNT=$(printf '%s' "$TRACKER_ROWS_JSON" | jq 'length')
if [ "$TRACKER_COUNT" -gt 0 ]; then
  echo "EPICS"
  echo "================================================================"
  # Iterate tracker rows in priority order.
  while IFS= read -r row_json; do
    [ -n "$row_json" ] || continue
    t_num=$(printf '%s' "$row_json" | jq -r '.number')
    t_badge=$(printf '%s' "$row_json" | jq -r '.priority_badge')
    t_title=$(printf '%s' "$row_json" | jq -r '.title')
    printf '    %s #%s — %s\n' "$t_badge" "$t_num" "$t_title"
    open_children="${CHILDREN_BY_TRACKER[$t_num]:-}"
    if [ -z "$open_children" ]; then
      echo "        (all children closed — pending auto-close)"
      continue
    fi
    for c in $open_children; do
      child_row=$(printf '%s' "$ROWS_JSON" \
        | jq -c --argjson n "$c" '.[] | select(.number == $n)')
      if [ -z "$child_row" ]; then
        continue
      fi
      c_title=$(printf '%s' "$child_row" | jq -r '.title')
      c_stage=$(printf '%s' "$child_row" | jq -r '.stage')
      printf '        #%s — %s  (%s)\n' "$c" "$c_title" "$c_stage"
    done
  done < <(printf '%s' "$TRACKER_ROWS_JSON" | jq -c '.[]')
  echo "================================================================"
fi

ORPHAN_COUNT=$(printf '%s' "$ORPHAN_ROWS_JSON" | jq 'length')
if [ "$ORPHAN_COUNT" -gt 0 ]; then
  echo "ORPHANS"
  echo "================================================================"

  # Print named buckets in alphabetical order first
  echo "$BUCKETS" | grep -E '^named:' | sort | while IFS= read -r line; do
    bucket="${line#named:}"
    echo " ($bucket)"
    printf '%s' "$ORPHAN_ROWS_JSON" \
      | jq -r --arg b "$bucket" '
          [.[] | select(.scope == $b)]
          | sort_by(.priority_tier, .number)
          | .[] | "    \(.priority_badge) #\(.number) — \(.title)  (\(.stage))"
        '
  done
  # Then the (none / generic) bucket, if present
  if echo "$BUCKETS" | grep -q '^generic:'; then
    echo " (none / generic)"
    printf '%s' "$ORPHAN_ROWS_JSON" \
      | jq -r '
          [.[] | select(.scope == "")]
          | sort_by(.priority_tier, .number)
          | .[] | "    \(.priority_badge) #\(.number) — \(.title)  (\(.stage))"
        '
  fi
  echo "================================================================"
fi
