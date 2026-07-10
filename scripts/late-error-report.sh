#!/bin/bash
set -uo pipefail
#
# late-error-report.sh — DOGFOOD-ONLY measurement (issue #574 / parent #450).
#
# Walks the last N merged feature PRs in $PIPELINE_REPO, extracts each
# `## Evaluation` "Changes Requested" finding, and categorizes it by the
# earliest stage at which it was detectable: issue|plan|plan-eval|pr-eval.
# Emits a per-PATH summary table plus a TOP-5 outlier list of PRs with the
# highest late-detectable rate.
#
# v0 categorization is a literal substring match against an explicit
# [stage: ...] marker on each finding line. Missing tag → defaults to
# pr-eval (conservative: counts as "not late-detectable"). Body-similarity
# inference is a follow-up.
#
# This script is repo-local dogfood instrumentation. It is NOT shipped in
# the plugin manifest and writes nothing under ${CLAUDE_PLUGIN_ROOT}.
#
# Usage:
#   bash scripts/late-error-report.sh                       # live (calls gh)
#   bash scripts/late-error-report.sh --limit 100           # window size
#   bash scripts/late-error-report.sh --fixture <dir>       # fixture mode
#   bash scripts/late-error-report.sh --dry-run             # list PRs only
#   bash scripts/late-error-report.sh --emit-rows-json      # debug: TSV-as-JSON
#   bash scripts/late-error-report.sh --help
#

LIMIT=50
FIXTURE_DIR=""
DRY_RUN=0
EMIT_ROWS_JSON=0

# Stage vocabulary (v0): four values. Order matters for default fallback —
# unrecognized/missing tags default to the last entry (pr-eval).
STAGE_VOCAB="issue plan plan-eval pr-eval"
DEFAULT_STAGE="pr-eval"

print_usage() {
  cat <<'USAGE'
Usage: late-error-report.sh [--limit N] [--fixture DIR] [--dry-run] [--emit-rows-json] [--help]

  --limit N           Number of most-recent merged PRs to walk (default: 50).
  --fixture DIR       Read prs.json / pr-<N>.json / issue-<N>.json from DIR
                      instead of calling `gh`. Used by the test suite.
  --dry-run           Fetch the PR list, print "would-fetch: PR #<N>" for each,
                      and exit without calling `gh issue view`.
  --emit-rows-json    Debug: emit the per-finding row TSV re-encoded as JSON
                      to stdout instead of the formatted table. Test-mode only.
  --help              Print this banner and exit 0.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)         print_usage; exit 0 ;;
    --limit)           LIMIT="${2:-}"; shift 2 ;;
    --limit=*)         LIMIT="${1#--limit=}"; shift ;;
    --fixture)         FIXTURE_DIR="${2:-}"; shift 2 ;;
    --fixture=*)       FIXTURE_DIR="${1#--fixture=}"; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --emit-rows-json)  EMIT_ROWS_JSON=1; shift ;;
    *)
      echo "late-error-report: ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# --- I/O helpers (fixture-aware), mirrored from over-eval-report.sh ---

load_pr_list() {
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/prs.json" ]; then
      echo "late-error-report: ERROR: fixture prs.json not found at $FIXTURE_DIR/prs.json" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/prs.json"
  else
    if [ -z "${PIPELINE_REPO:-}" ]; then
      echo "late-error-report: ERROR: PIPELINE_REPO not set" >&2
      return 1
    fi
    gh pr list \
      --repo "$PIPELINE_REPO" \
      --state merged \
      --limit "$LIMIT" \
      --json number,title,additions,deletions,body,mergedAt,labels
  fi
}

# Release-PR detection: same rule set as over-eval-report.sh — OR-combined.
RELEASE_PR_JQ='(
  ((.labels // []) | any(.name == "autorelease: tagged" or .name == "autorelease: pending"))
  or ((.title // "") | test("^chore\\(main\\): release"))
  or ((.title // "") | test("^release: v"))
  or ((.title // "") | test("^chore\\(release\\):"))
)'

load_pr_view() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/pr-$num.json" ]; then
      echo "late-error-report: WARN: fixture pr-$num.json missing; skipping PR #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/pr-$num.json"
  else
    gh pr view "$num" \
      --repo "$PIPELINE_REPO" \
      --json number,additions,deletions,comments
  fi
}

load_issue_view() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/issue-$num.json" ]; then
      echo "late-error-report: WARN: fixture issue-$num.json missing; skipping issue #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/issue-$num.json"
  else
    gh issue view "$num" \
      --repo "$PIPELINE_REPO" \
      --json number,labels,comments
  fi
}

extract_linked_issue() {
  printf '%s\n' "$1" \
    | grep -iEo '(closes|fixes|resolves)[[:space:]]+#[0-9]+' \
    | head -1 \
    | grep -Eo '[0-9]+'
}

derive_path() {
  local labels_json="$1"
  if printf '%s' "$labels_json" | jq -e 'any(.[]; .name == "docs-only")' >/dev/null 2>&1; then
    echo "A"
  elif printf '%s' "$labels_json" | jq -e 'any(.[]; .name == "quick-fix")' >/dev/null 2>&1; then
    echo "D"
  elif printf '%s' "$labels_json" | jq -e 'any(.[]; .name == "multi-task")' >/dev/null 2>&1; then
    echo "C"
  else
    echo "B"
  fi
}

# latest_eval_body <comments-json>
#   Pick the latest comment whose body contains `## Evaluation` at the start
#   of a line. Emits the body string, or empty when no such comment exists.
latest_eval_body() {
  local comments="$1"
  printf '%s' "$comments" \
    | jq -r '
        map(select(.body | test("(?m)^## Evaluation")))
        | sort_by(.createdAt // "")
        | last
        | if . == null then "" else .body end
      '
}

# extract_findings <eval-body>
#   Print one finding per line. A finding is a top-level list line under the
#   "Changes Requested" verdict — either `- ...` or `<digit+>. ...`.
#   The scan starts at the line containing "Changes Requested" and stops at
#   the next top-level `## ` heading or EOF. Indented list items (nested
#   bullets) are skipped — only column-0 list markers count.
extract_findings() {
  local body="$1"
  printf '%s\n' "$body" | awk '
    BEGIN { in_section = 0 }
    {
      # Stop at next ## heading once we are inside the findings section.
      if (in_section && substr($0, 1, 3) == "## ") { exit }
      if (!in_section) {
        if (tolower($0) ~ /changes requested/) { in_section = 1 }
        next
      }
      # Top-level bullet (- ...) or numbered (1. ...) at column 0.
      if ($0 ~ /^- /)       { print substr($0, 3); next }
      if ($0 ~ /^[0-9]+\. /) {
        sub(/^[0-9]+\. /, "", $0)
        print $0
      }
    }
  '
}

# detect_stage <finding-line>
#   Scan the line for an explicit `[stage: <value>]` marker (case-insensitive).
#   Emits the matched value if it is in $STAGE_VOCAB; otherwise emits
#   $DEFAULT_STAGE. The first match wins.
detect_stage() {
  local line="$1"
  local lower
  lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
  local tag
  for tag in $STAGE_VOCAB; do
    if printf '%s' "$lower" | grep -qF "[stage: $tag]"; then
      echo "$tag"
      return 0
    fi
  done
  echo "$DEFAULT_STAGE"
}

# truncate_excerpt <text>
#   Cap to ~60 chars for the outlier list and TSV excerpt column.
truncate_excerpt() {
  local s="$1"
  if [ "${#s}" -le 60 ]; then
    printf '%s' "$s"
  else
    printf '%s' "${s:0:57}..."
  fi
}

# --- temp files ---
ROWS_TSV=$(mktemp)
trap 'rm -f "$ROWS_TSV"' EXIT

# --- main loop ---

RAW_PR_LIST_JSON="$(load_pr_list)" || exit 1

RELEASE_PR_COUNT="$(printf '%s' "$RAW_PR_LIST_JSON" | jq "[.[] | select($RELEASE_PR_JQ)] | length" 2>/dev/null || echo 0)"
PR_LIST_JSON="$(printf '%s' "$RAW_PR_LIST_JSON" | jq "[.[] | select($RELEASE_PR_JQ | not)]" 2>/dev/null || echo '[]')"
PR_COUNT="$(printf '%s' "$PR_LIST_JSON" | jq 'length' 2>/dev/null || echo 0)"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s' "$PR_LIST_JSON" | jq -r '.[].number' | tr -d '\r' | while read -r n; do
    echo "would-fetch: PR #$n"
  done
  exit 0
fi

SKIPPED_NO_LINK=0
while read -r pr; do
  pr_num=$(printf '%s' "$pr" | jq -r '.number' | tr -d '\r')
  pr_body=$(printf '%s' "$pr" | jq -r '.body // ""')

  issue_num="$(extract_linked_issue "$pr_body")"
  if [ -z "$issue_num" ]; then
    SKIPPED_NO_LINK=$((SKIPPED_NO_LINK + 1))
    continue
  fi

  pr_view="$(load_pr_view "$pr_num" 2>/dev/null)" || continue
  issue_view="$(load_issue_view "$issue_num" 2>/dev/null)" || continue

  issue_labels="$(printf '%s' "$issue_view" | jq -c '.labels // []')"
  path="$(derive_path "$issue_labels")"

  pr_comments="$(printf '%s' "$pr_view" | jq -c '.comments // []')"
  eval_body="$(latest_eval_body "$pr_comments")"
  if [ -z "$eval_body" ]; then
    continue
  fi

  finding_idx=0
  while IFS= read -r finding; do
    [ -z "$finding" ] && continue
    finding_idx=$((finding_idx + 1))
    stage="$(detect_stage "$finding")"
    excerpt="$(truncate_excerpt "$finding")"
    # Columns: path<TAB>pr_number<TAB>stage<TAB>finding_index<TAB>excerpt
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$path" "$pr_num" "$stage" "$finding_idx" "$excerpt" \
      >> "$ROWS_TSV"
  done < <(extract_findings "$eval_body")
done < <(printf '%s' "$PR_LIST_JSON" | jq -c '.[]')

if [ "$SKIPPED_NO_LINK" -gt 0 ]; then
  echo "late-error-report: $SKIPPED_NO_LINK non-release PRs skipped for missing Closes/Fixes/Resolves marker" >&2
fi

# --- output ---

emit_rows_json() {
  # Re-encode TSV → JSON array of objects. Use jq to avoid shell-quoting issues
  # in the excerpt column (which may contain commas, quotes, etc.).
  if [ ! -s "$ROWS_TSV" ]; then
    echo "[]"
    return 0
  fi
  jq -Rs '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map({
        path: .[0],
        pr_number: (.[1] | tonumber),
        stage: .[2],
        finding_index: (.[3] | tonumber),
        excerpt: .[4]
      })
  ' < "$ROWS_TSV"
}

if [ "$EMIT_ROWS_JSON" -eq 1 ]; then
  emit_rows_json
  exit 0
fi

# --- per-PATH aggregation + table render ---

emit_table() {
  local oldest newest
  oldest="$(printf '%s' "$PR_LIST_JSON" | jq -r '[.[].mergedAt // empty] | min // "?"')"
  newest="$(printf '%s' "$PR_LIST_JSON" | jq -r '[.[].mergedAt // empty] | max // "?"')"
  if [ "$RELEASE_PR_COUNT" -gt 0 ]; then
    printf 'LATE-ERROR REPORT — last %s feature PRs (window: %s to %s; %s release PRs excluded)\n\n' \
      "$PR_COUNT" "$oldest" "$newest" "$RELEASE_PR_COUNT"
  else
    printf 'LATE-ERROR REPORT — last %s feature PRs (window: %s to %s)\n\n' \
      "$PR_COUNT" "$oldest" "$newest"
  fi

  echo 'PATH | N findings | issue | plan | plan-eval | pr-eval | late-detectable rate'

  sort -k1,1 "$ROWS_TSV" | awk -F'\t' '
    function emit_row(    total, late, rate) {
      if (cur == "") return
      total = c_issue + c_plan + c_plan_eval + c_pr_eval
      late = c_issue + c_plan + c_plan_eval
      if (total > 0) rate = sprintf("%.2f", late / total); else rate = "--"
      printf "%-4s | %-10d | %-5d | %-4d | %-9d | %-7d | %s\n", \
        cur, total, c_issue, c_plan, c_plan_eval, c_pr_eval, rate
      cur = ""; c_issue = 0; c_plan = 0; c_plan_eval = 0; c_pr_eval = 0
    }
    BEGIN { cur = ""; c_issue = 0; c_plan = 0; c_plan_eval = 0; c_pr_eval = 0 }
    {
      path = $1; stage = $3
      if (path != cur) { emit_row(); cur = path }
      if (stage == "issue")          c_issue++
      else if (stage == "plan")      c_plan++
      else if (stage == "plan-eval") c_plan_eval++
      else                           c_pr_eval++
    }
    END { emit_row() }
  '
}

emit_table

# --- TOP-5 outliers (per-PR late-detectable rate, descending) ---

emit_outliers() {
  echo ""
  echo "TOP-5 LATE-ERROR OUTLIERS (highest per-PR late-detectable rate):"
  awk -F'\t' '
    {
      path = $1; pr_num = $2; stage = $3
      key = pr_num
      paths[key] = path
      totals[key]++
      if (stage == "issue" || stage == "plan" || stage == "plan-eval") {
        lates[key]++
      }
    }
    END {
      for (k in totals) {
        late = (k in lates) ? lates[k] : 0
        rate = late / totals[k]
        printf "%.6f\t%s\t%d\t%d\t%s\n", rate, paths[k], late, totals[k], k
      }
    }
  ' "$ROWS_TSV" \
  | sort -t "$(printf '\t')" -k1,1 -gr \
  | head -5 \
  | awk -F'\t' '{ printf "PR #%s (PATH %s): %d/%d findings late-detectable → %.2f\n", $5, $2, $3, $4, $1 }'
}

emit_outliers
