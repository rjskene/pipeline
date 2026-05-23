#!/bin/bash
set -uo pipefail
#
# over-eval-report.sh — DOGFOOD-ONLY one-off measurement (issue #419).
#
# Walks the last N merged PRs in $PIPELINE_REPO and emits a per-PATH summary
# table comparing PR diff size against plan / plan-eval / pr-eval verbosity,
# plus a top-5 outlier list ranked by pr-eval-to-diff ratio.
#
# This script is for this repo's own dogfood operation only. It is NOT shipped
# in the plugin manifest and writes nothing under ${CLAUDE_PLUGIN_ROOT}.
#
# Usage:
#   bash scripts/over-eval-report.sh                       # live (calls gh)
#   bash scripts/over-eval-report.sh --limit 100           # window size
#   bash scripts/over-eval-report.sh --fixture <dir>       # fixture mode
#   bash scripts/over-eval-report.sh --dry-run             # list PRs only
#   bash scripts/over-eval-report.sh --emit-rows-json      # debug: TSV-as-JSON
#   bash scripts/over-eval-report.sh --help
#

LIMIT=50
FIXTURE_DIR=""
DRY_RUN=0
EMIT_ROWS_JSON=0

print_usage() {
  cat <<'USAGE'
Usage: over-eval-report.sh [--limit N] [--fixture DIR] [--dry-run] [--emit-rows-json] [--help]

  --limit N           Number of most-recent merged PRs to walk (default: 50).
  --fixture DIR       Read prs.json / pr-<N>.json / issue-<N>.json from DIR
                      instead of calling `gh`. Used by the test suite.
  --dry-run           Fetch the PR list, print "would-fetch: PR #<N>" for each,
                      and exit without calling `gh issue view`.
  --emit-rows-json    Debug: emit the per-PR row TSV re-encoded as JSON to
                      stdout instead of the formatted table. Test-mode only.
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
      echo "over-eval-report: ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# --- I/O helpers (fixture-aware) ---

# load_pr_list — print the merged-PR list as a JSON array of objects with at
# least {number, additions, deletions, body, mergedAt}. Fixture mode reads
# prs.json; live mode calls `gh pr list ... --json ...`.
load_pr_list() {
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/prs.json" ]; then
      echo "over-eval-report: ERROR: fixture prs.json not found at $FIXTURE_DIR/prs.json" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/prs.json"
  else
    if [ -z "${PIPELINE_REPO:-}" ]; then
      echo "over-eval-report: ERROR: PIPELINE_REPO not set" >&2
      return 1
    fi
    gh pr list \
      --repo "$PIPELINE_REPO" \
      --state merged \
      --limit "$LIMIT" \
      --json number,title,additions,deletions,body,mergedAt
  fi
}

# load_pr_view <num> — print the per-PR JSON payload including comments.
load_pr_view() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/pr-$num.json" ]; then
      echo "over-eval-report: WARN: fixture pr-$num.json missing; skipping PR #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/pr-$num.json"
  else
    gh pr view "$num" \
      --repo "$PIPELINE_REPO" \
      --json number,additions,deletions,comments
  fi
}

# load_issue_view <num> — print the per-issue JSON payload including labels +
# comments (the planner posts ## Implementation Plan / ## Plan Evaluation here).
load_issue_view() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/issue-$num.json" ]; then
      echo "over-eval-report: WARN: fixture issue-$num.json missing; skipping issue #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/issue-$num.json"
  else
    gh issue view "$num" \
      --repo "$PIPELINE_REPO" \
      --json number,labels,comments
  fi
}

# extract_linked_issue <pr-body> — read "Closes #<N>" / "Fixes #<N>" / "Resolves
# #<N>" markers from a PR body and emit the first matched issue number, or
# empty string when none found.
extract_linked_issue() {
  printf '%s\n' "$1" \
    | grep -iEo '(closes|fixes|resolves)[[:space:]]+#[0-9]+' \
    | head -1 \
    | grep -Eo '[0-9]+'
}

# derive_path <labels-json> — map issue labels to PATH letter using the
# precedence in CLAUDE.md / skills/classify-issue:
#   docs-only  → A
#   quick-fix  → D
#   multi-task → C
#   else       → B
# <labels-json> is the `.labels` array from `gh issue view --json labels`.
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

# count_block_lines <body> <heading> — count the lines of the markdown block
# starting at `## <heading>` and terminating before the next top-level `## `
# heading or EOF (heading line included). Emits an integer line count.
# When the heading is absent from <body>, emits the empty string.
count_block_lines() {
  local body="$1"
  local heading="$2"
  printf '%s\n' "$body" | awk -v h="## $heading" '
    BEGIN { in_block = 0; n = 0 }
    {
      if ($0 == h) { in_block = 1; n = 1; next }
      if (in_block) {
        if (substr($0, 1, 3) == "## ") { exit }
        n++
      }
    }
    END { if (in_block) print n }'
}

# latest_block_lines <comments-json> <heading>
#   Iterate comments (newest createdAt last), find the most-recent comment
#   whose body contains `## <heading>` at the start of a line, and emit the
#   line count of that block. When no comment contains the heading, emits
#   the empty string.
latest_block_lines() {
  local comments="$1"
  local heading="$2"
  # Sort by createdAt ascending so the last match wins, then pick last.
  local latest_body
  latest_body="$(
    printf '%s' "$comments" \
      | jq -r --arg h "## $heading" '
          map(select(.body | test("(?m)^" + ($h | gsub("[.\\\\+*?^$()\\[\\]{}|]"; "\\\\\\0")))))
          | sort_by(.createdAt // "")
          | last
          | if . == null then "" else .body end
        '
  )"
  if [ -z "$latest_body" ]; then
    return 0  # emit empty
  fi
  count_block_lines "$latest_body" "$heading"
}

# --- temp files ---
ROWS_TSV=$(mktemp)
trap 'rm -f "$ROWS_TSV"' EXIT

# --- main loop: iterate PRs, emit one TSV row per PR ---

PR_LIST_JSON="$(load_pr_list)" || exit 1

PR_COUNT="$(printf '%s' "$PR_LIST_JSON" | jq 'length' 2>/dev/null || echo 0)"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s' "$PR_LIST_JSON" | jq -r '.[].number' | while read -r n; do
    echo "would-fetch: PR #$n"
  done
  exit 0
fi

# Iterate PRs (process substitution preserves variable scope; we don't need it
# here because we write to a temp file, but keep simple `while read`).
printf '%s' "$PR_LIST_JSON" \
  | jq -c '.[]' \
  | while read -r pr; do
      pr_num=$(printf '%s' "$pr" | jq -r '.number')
      pr_body=$(printf '%s' "$pr" | jq -r '.body // ""')
      pr_additions=$(printf '%s' "$pr" | jq -r '.additions // 0')
      pr_deletions=$(printf '%s' "$pr" | jq -r '.deletions // 0')
      loc=$((pr_additions + pr_deletions))

      issue_num="$(extract_linked_issue "$pr_body")"
      if [ -z "$issue_num" ]; then
        echo "over-eval-report: DEBUG: PR #$pr_num has no linked issue; skipping" >&2
        continue
      fi

      pr_view="$(load_pr_view "$pr_num" 2>/dev/null)" || continue
      issue_view="$(load_issue_view "$issue_num" 2>/dev/null)" || continue

      issue_labels="$(printf '%s' "$issue_view" | jq -c '.labels // []')"
      path="$(derive_path "$issue_labels")"

      issue_comments="$(printf '%s' "$issue_view" | jq -c '.comments // []')"
      pr_comments="$(printf '%s' "$pr_view"    | jq -c '.comments // []')"

      plan_lines="$(latest_block_lines "$issue_comments" "Implementation Plan")"
      plan_eval_lines="$(latest_block_lines "$issue_comments" "Plan Evaluation")"
      pr_eval_lines="$(latest_block_lines "$pr_comments"    "Evaluation")"

      # Fallbacks: missing block → 0 lines (semantically "absent"). Plan-eval
      # absence renders as "--" so the operator can tell "lifecycle skipped"
      # apart from "real zero" (cf. design decision in plan).
      [ -z "$plan_lines" ]      && plan_lines=0
      [ -z "$plan_eval_lines" ] && plan_eval_lines="--"
      [ -z "$pr_eval_lines" ]   && pr_eval_lines=0

      # Columns: path<TAB>loc<TAB>plan<TAB>plan_eval<TAB>pr_eval<TAB>pr_number
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$loc" "$plan_lines" "$plan_eval_lines" "$pr_eval_lines" "$pr_num" \
        >> "$ROWS_TSV"
    done

# --- output ---

emit_rows_json() {
  # Re-encode the TSV as a JSON array of objects for the test suite.
  awk -F'\t' 'BEGIN { print "[" }
    {
      if (NR > 1) print ",";
      printf "  {\"path\":\"%s\",\"loc\":%s,\"plan\":%s,\"plan_eval\":\"%s\",\"pr_eval\":%s,\"pr_number\":%s}", $1, $2, $3, $4, $5, $6
    }
    END { print "\n]" }' "$ROWS_TSV"
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
  printf 'OVER-EVAL REPORT — last %s merged PRs (window: %s to %s)\n\n' \
    "$LIMIT" "$oldest" "$newest"

  echo 'PATH | N  | median diff | median plan | median plan-eval | median pr-eval | ratio pr-eval:diff | ratio plan-eval:diff'

  sort -k1,1 "$ROWS_TSV" | awk -F'\t' '
    function fmt(v) {
      # Print integers cleanly (4 not 4.0); floats with one decimal.
      if (v == int(v)) return sprintf("%d", v)
      return sprintf("%.1f", v)
    }
    function median(arr, n,    i, j, tmp, mid) {
      for (i=1; i<n; i++) {
        for (j=i+1; j<=n; j++) {
          if (arr[i] > arr[j]) { tmp=arr[i]; arr[i]=arr[j]; arr[j]=tmp }
        }
      }
      if (n == 0) return ""
      if (n % 2 == 1) return arr[(n+1)/2]
      mid = (arr[n/2] + arr[n/2+1]) / 2
      return mid
    }
    function emit_row(    diff_m, plan_m, plan_eval_m, pr_eval_m, r_pre, r_ple) {
      if (cur == "") return
      diff_m = median(locs, n)
      plan_m = median(plans, n)
      pr_eval_m = median(pr_evals, n)
      if (peval_n > 0) plan_eval_m = median(peval_vals, peval_n); else plan_eval_m = ""

      if (diff_m > 0) r_pre = sprintf("%.1fx", pr_eval_m / diff_m); else r_pre = "--"
      if (diff_m > 0 && plan_eval_m != "") r_ple = sprintf("%.1fx", plan_eval_m / diff_m); else r_ple = "--"

      printf "%-4s | %-2d | %-11s | %-11s | %-16s | %-14s | %-18s | %-21s\n", \
        cur, n, fmt(diff_m), fmt(plan_m), \
        (plan_eval_m == "" ? "--" : fmt(plan_eval_m)), \
        fmt(pr_eval_m), r_pre, r_ple

      cur=""; n=0; peval_n=0
      delete locs; delete plans; delete pr_evals; delete peval_vals
    }
    {
      path = $1
      if (path != cur) { emit_row(); cur = path }
      n++
      locs[n] = $2
      plans[n] = $3
      if ($4 != "--") { peval_n++; peval_vals[peval_n] = $4 }
      pr_evals[n] = $5
    }
    END { emit_row() }'
}

emit_table
