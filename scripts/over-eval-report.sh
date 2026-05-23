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

      issue_num="$(extract_linked_issue "$pr_body")"
      if [ -z "$issue_num" ]; then
        echo "over-eval-report: DEBUG: PR #$pr_num has no linked issue; skipping" >&2
        continue
      fi

      # Load full PR + issue payloads (Task 3 will mine these for metrics).
      load_pr_view "$pr_num"   >/dev/null || continue
      load_issue_view "$issue_num" >/dev/null || continue

      # Task 2 placeholder row — Task 3 replaces with real metrics.
      # Columns: path<TAB>loc<TAB>plan<TAB>plan_eval<TAB>pr_eval<TAB>pr_number
      printf '?\t0\t0\t--\t0\t%s\n' "$pr_num" >> "$ROWS_TSV"
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

# Default: stub stdout for Task 2; Task 4 renders the real table.
echo "over-eval-report: scaffolding stub — formatted table arrives in a later commit."
exit 0
