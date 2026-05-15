#!/bin/bash
set -euo pipefail
#
# find-grouping-candidates.sh — score proposed issue titles against the
# open-issues list and emit a single recommendation line per input title.
#
# Output line shape (stable contract; matched verbatim by skill prose and
# tests/test-find-grouping-candidates.sh):
#
#   INPUT="<title>" REC=<TRACKER #N | GROUP #A,#B,... | STANDALONE> REASON=<short>
#
# Usage:
#   bash scripts/find-grouping-candidates.sh --title "<title>" [--title "<title>" ...]
#   bash scripts/find-grouping-candidates.sh "<title>" ["<title>" ...]
#
# Decision logic (deterministic; v1):
#   1. Extract conventional-commit <scope> token from the title via regex.
#      No scope → STANDALONE (REASON=no-scope-prefix).
#   2. If exactly one open `tracker`-labelled issue has title `epic(<scope>):` →
#      TRACKER #<n> (REASON=scope-match). Multiple → lowest-numbered with
#      REASON=scope-match-multiple.
#   3. Else if ≥ 2 open non-tracker issues share the scope prefix → GROUP
#      #<n1>,#<n2>,... (REASON=cluster-of-N where N includes the proposed).
#   4. Else → STANDALONE (REASON=no-cluster).
#
# The helper itself NEVER edits issues — it only reads `gh issue list`.

# --- locate and source pipeline.config ---
find_config() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/pipeline.config" ]; then
      printf '%s\n' "$dir/pipeline.config"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

CFG="$(find_config || true)"
if [ -z "$CFG" ]; then
  echo "find-grouping-candidates: ERROR: pipeline.config not found in $PWD or any ancestor" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$CFG"

if [ -z "${PIPELINE_REPO:-}" ]; then
  echo "find-grouping-candidates: ERROR: PIPELINE_REPO not set in $CFG" >&2
  exit 1
fi

# --- parse args (one or more titles) ---
titles=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title)
      [ $# -ge 2 ] || { echo "find-grouping-candidates: ERROR: --title requires a value" >&2; exit 1; }
      titles+=("$2"); shift 2 ;;
    --title=*)
      titles+=("${1#--title=}"); shift ;;
    --) shift; while [ $# -gt 0 ]; do titles+=("$1"); shift; done ;;
    -*)
      echo "find-grouping-candidates: ERROR: unknown flag: $1" >&2; exit 1 ;;
    *)
      titles+=("$1"); shift ;;
  esac
done

if [ "${#titles[@]}" -eq 0 ]; then
  echo "find-grouping-candidates: ERROR: at least one --title required" >&2
  exit 1
fi

# --- one gh call, cached for the run ---
ISSUES_FILE=$(mktemp); trap 'rm -f "$ISSUES_FILE"' EXIT
gh issue list \
  --repo "$PIPELINE_REPO" \
  --state open \
  --limit 200 \
  --json number,title,body,labels \
  > "$ISSUES_FILE"

# --- helpers ---
scope_of() {
  # echoes the <scope> token (e.g. "harness-isolation") or empty.
  printf '%s' "$1" | sed -nE 's/^[a-z]+\(([a-z0-9_-]+)\):.*/\1/p'
}

# Emit one recommendation per input.
for input in "${titles[@]}"; do
  scope="$(scope_of "$input")"

  if [ -z "$scope" ]; then
    printf 'INPUT="%s" REC=STANDALONE REASON=no-scope-prefix\n' "$input"
    continue
  fi

  # Tracker match: issues whose labels include `tracker` AND whose title
  # matches `epic(<scope>):`. Output: numbers, one per line, ascending.
  tracker_nums=$(jq -r --arg scope "$scope" '
    [ .[]
      | select(.labels | map(.name) | index("tracker"))
      | select(.title | test("^epic\\(" + $scope + "\\):"))
      | .number
    ] | sort | .[]
  ' "$ISSUES_FILE")

  if [ -n "$tracker_nums" ]; then
    first_tracker=$(printf '%s\n' "$tracker_nums" | head -n 1)
    count=$(printf '%s\n' "$tracker_nums" | wc -l | tr -d ' ')
    if [ "$count" -gt 1 ]; then
      printf 'INPUT="%s" REC=TRACKER #%s REASON=scope-match-multiple\n' "$input" "$first_tracker"
    else
      printf 'INPUT="%s" REC=TRACKER #%s REASON=scope-match\n' "$input" "$first_tracker"
    fi
    continue
  fi

  # Standalone cluster: non-tracker open issues whose title shares the scope.
  cluster_nums=$(jq -r --arg scope "$scope" '
    [ .[]
      | select(.labels | map(.name) | index("tracker") | not)
      | select(.title | test("^[a-z]+\\(" + $scope + "\\):"))
      | .number
    ] | sort | .[]
  ' "$ISSUES_FILE")

  cluster_count=0
  if [ -n "$cluster_nums" ]; then
    cluster_count=$(printf '%s\n' "$cluster_nums" | wc -l | tr -d ' ')
  fi

  if [ "$cluster_count" -ge 2 ]; then
    # Format as #A,#B,...
    formatted=$(printf '%s\n' "$cluster_nums" | awk 'NR==1{printf "#%s",$0; next} {printf ",#%s",$0}')
    total=$((cluster_count + 1))
    printf 'INPUT="%s" REC=GROUP %s REASON=cluster-of-%d\n' "$input" "$formatted" "$total"
    continue
  fi

  printf 'INPUT="%s" REC=STANDALONE REASON=no-cluster\n' "$input"
done
