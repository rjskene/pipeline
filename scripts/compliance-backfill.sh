#!/bin/bash
set -uo pipefail
#
# compliance-backfill.sh — DOGFOOD-ONLY retroactive TDD-compliance verdict
# backfill (issue #575).
#
# Walks the last N merged feature PRs in $PIPELINE_REPO and drives
# scripts/audit-compliance.sh (#417, PASS/SKIP/N-A red→green git signature)
# over each via the injection-flag interface (--commits-json, --files-json,
# --labels-json) introduced by #432. Because the underlying verdict is
# derived purely from each PR's git commit signature, this can be computed
# RETROACTIVELY over already-merged PRs — no edit to evaluate-issue-pr or
# any skill is required (the whole point: honor the "nothing in the
# skills/runtime" rule from feedback_dogfood_instrumentation_no_consumer_crud).
#
# Output: per-PATH PASS/SKIP/N-A aggregation table on stdout plus an overall
# SKIP-rate footer. --emit-rows-json is the forward contract for #576's
# metrics-snapshot.sh (one object per eligible feature PR, keys
# {pr_number, path, verdict, issue_number}).
#
# audit-compliance.sh is ALWAYS invoked with --dry-run — we are computing
# retroactively over already-merged PRs and must not post ## Compliance
# Audit comments back onto them.
#
# This script is for this repo's own dogfood operation only. It is NOT
# shipped in the plugin manifest and writes nothing under ${CLAUDE_PLUGIN_ROOT}.
#
# Shared-helper boundary: load_pr_list / load_pr_view / load_issue_view /
# extract_linked_issue / derive_path / RELEASE_PR_JQ are inline-copied
# verbatim from scripts/over-eval-report.sh. A future refactor PR may
# extract these to scripts/lib/pr-walk.sh if a third caller appears.
#
# Usage:
#   bash scripts/compliance-backfill.sh                       # live (calls gh)
#   bash scripts/compliance-backfill.sh --limit 100           # window size
#   bash scripts/compliance-backfill.sh --fixture <dir>       # fixture mode
#   bash scripts/compliance-backfill.sh --dry-run             # list PRs only
#   bash scripts/compliance-backfill.sh --emit-rows-json      # JSON array
#   bash scripts/compliance-backfill.sh --help
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_COMPLIANCE="$SCRIPT_DIR/audit-compliance.sh"

LIMIT=50
FIXTURE_DIR=""
DRY_RUN=0
EMIT_ROWS_JSON=0

print_usage() {
  cat <<'USAGE'
Usage: compliance-backfill.sh [--limit N] [--fixture DIR] [--dry-run] [--emit-rows-json] [--help]

  --limit N           Number of most-recent merged PRs to walk (default: 50).
  --fixture DIR       Read prs.json / pr-<N>.json / issue-<N>.json /
                      commits-<N>.json / files-<N>.json from DIR instead of
                      calling `gh`. Used by the test suite.
  --dry-run           Fetch the PR list, print "would-fetch: PR #<N>" for each,
                      and exit without invoking audit-compliance.sh.
  --emit-rows-json    Emit the per-PR row array as JSON to stdout instead of
                      the formatted aggregation table. Forward contract for
                      metrics-snapshot.sh (#576).
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
      echo "compliance-backfill: ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# --- I/O helpers (fixture-aware) — verbatim from over-eval-report.sh ---

# load_pr_list — print the merged-PR list as a JSON array of objects with at
# least {number, additions, deletions, body, mergedAt, labels}.
load_pr_list() {
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/prs.json" ]; then
      echo "compliance-backfill: ERROR: fixture prs.json not found at $FIXTURE_DIR/prs.json" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/prs.json"
  else
    if [ -z "${PIPELINE_REPO:-}" ]; then
      echo "compliance-backfill: ERROR: PIPELINE_REPO not set" >&2
      return 1
    fi
    gh pr list \
      --repo "$PIPELINE_REPO" \
      --state merged \
      --limit "$LIMIT" \
      --json number,title,additions,deletions,body,mergedAt,labels
  fi
}

# Release-PR detection — verbatim from over-eval-report.sh.
RELEASE_PR_JQ='(
  ((.labels // []) | any(.name == "autorelease: tagged" or .name == "autorelease: pending"))
  or ((.title // "") | test("^chore\\(main\\): release"))
  or ((.title // "") | test("^release: v"))
  or ((.title // "") | test("^chore\\(release\\):"))
)'

# load_pr_view <num> — verbatim from over-eval-report.sh.
load_pr_view() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/pr-$num.json" ]; then
      echo "compliance-backfill: WARN: fixture pr-$num.json missing; skipping PR #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/pr-$num.json"
  else
    gh pr view "$num" \
      --repo "$PIPELINE_REPO" \
      --json number,additions,deletions,comments
  fi
}

# load_issue_view <num> — verbatim from over-eval-report.sh.
load_issue_view() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/issue-$num.json" ]; then
      echo "compliance-backfill: WARN: fixture issue-$num.json missing; skipping issue #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/issue-$num.json"
  else
    gh issue view "$num" \
      --repo "$PIPELINE_REPO" \
      --json number,labels,comments
  fi
}

# extract_linked_issue <pr-body> — verbatim from over-eval-report.sh.
extract_linked_issue() {
  printf '%s\n' "$1" \
    | grep -iEo '(closes|fixes|resolves)[[:space:]]+#[0-9]+' \
    | head -1 \
    | grep -Eo '[0-9]+'
}

# derive_path <labels-json> — verbatim from over-eval-report.sh.
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

# --- compliance-backfill-specific loaders ---

# load_pr_commits <num> — print the `[{oid, files:[paths]}, ...]` payload
# audit-compliance.sh's --commits-json injection flag consumes.
# Fixture mode: read commits-<N>.json. Live mode: per-sha API join.
load_pr_commits() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/commits-$num.json" ]; then
      echo "compliance-backfill: WARN: fixture commits-$num.json missing; skipping PR #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/commits-$num.json"
  else
    # gh pr view --json commits does NOT return per-commit file lists; we
    # join the commit-list + per-sha commit detail calls. N call-amplified
    # (1 + N per PR); rate-limit handling is unimplemented in v0 — operator
    # re-runs with a smaller --limit on 429/403.
    local shas
    shas="$(gh api "repos/$PIPELINE_REPO/pulls/$num/commits" --paginate --jq '.[].sha')" || return 1
    local out="["
    local first=1
    while IFS= read -r sha; do
      [ -z "$sha" ] && continue
      local files_json
      files_json="$(gh api "repos/$PIPELINE_REPO/commits/$sha" --jq '[.files[].filename]')" || return 1
      if [ "$first" = "1" ]; then first=0; else out+=","; fi
      out+="$(jq -nc --arg oid "$sha" --argjson files "$files_json" '{oid:$oid, files:$files}')"
    done <<<"$shas"
    out+="]"
    printf '%s' "$out"
  fi
}

# load_pr_files <num> — print the `[paths]` array for audit-compliance.sh's
# --files-json injection flag.
load_pr_files() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/files-$num.json" ]; then
      echo "compliance-backfill: WARN: fixture files-$num.json missing; skipping PR #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/files-$num.json"
  else
    gh api "repos/$PIPELINE_REPO/pulls/$num/files" --paginate --jq '[.[].filename]'
  fi
}

# extract_tdd_verdict <audit-stdout> — parse audit-compliance.sh's table for
# the TDD row's Verdict column. When the row is omitted (PATH A), emit
# 'omitted'. Else emit PASS / SKIP / N/A.
extract_tdd_verdict() {
  local audit_out="$1"
  local tdd_line
  tdd_line="$(printf '%s\n' "$audit_out" | grep -E '^\| TDD' | head -1)"
  if [ -z "$tdd_line" ]; then
    echo "omitted"
    return 0
  fi
  # Table row shape: `| TDD   | <expected> | <detected> | <verdict> |`
  # The Verdict column is the 4th `|`-delimited field.
  printf '%s' "$tdd_line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5); print $5}'
}

# --- main loop: iterate PRs, audit each, collect rows ---

ROWS_JSON_TMP=$(mktemp)
trap 'rm -f "$ROWS_JSON_TMP"' EXIT

RAW_PR_LIST_JSON="$(load_pr_list)" || exit 1

# Partition raw list into release PRs (excluded) and eligible feature PRs.
RELEASE_PR_COUNT="$(printf '%s' "$RAW_PR_LIST_JSON" | jq "[.[] | select($RELEASE_PR_JQ)] | length" 2>/dev/null || echo 0)"
PR_LIST_JSON="$(printf '%s' "$RAW_PR_LIST_JSON" | jq "[.[] | select($RELEASE_PR_JQ | not)]" 2>/dev/null || echo '[]')"

PR_COUNT="$(printf '%s' "$PR_LIST_JSON" | jq 'length' 2>/dev/null || echo 0)"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s' "$PR_LIST_JSON" | jq -r '.[].number' | while read -r n; do
    echo "would-fetch: PR #$n"
  done
  exit 0
fi

# Initialise the rows accumulator with an empty JSON array.
echo '[]' > "$ROWS_JSON_TMP"

SKIPPED_NO_LINK=0
while read -r pr; do
  pr_num=$(printf '%s' "$pr" | jq -r '.number')
  pr_body=$(printf '%s' "$pr" | jq -r '.body // ""')

  issue_num="$(extract_linked_issue "$pr_body")"
  if [ -z "$issue_num" ]; then
    SKIPPED_NO_LINK=$((SKIPPED_NO_LINK + 1))
    continue
  fi

  issue_view="$(load_issue_view "$issue_num" 2>/dev/null)" || continue
  issue_labels="$(printf '%s' "$issue_view" | jq -c '.labels // []')"
  path_letter="$(derive_path "$issue_labels")"

  commits_json="$(load_pr_commits "$pr_num" 2>/dev/null)" || continue
  files_json="$(load_pr_files "$pr_num" 2>/dev/null)" || continue

  # Stage injection JSON in a per-PR tempdir for audit-compliance.sh.
  per_pr_tmp="$(mktemp -d)"
  printf '%s' "$issue_labels" > "$per_pr_tmp/labels.json"
  printf '%s' "$files_json"   > "$per_pr_tmp/files.json"
  printf '%s' "$commits_json" > "$per_pr_tmp/commits.json"

  audit_out="$(bash "$AUDIT_COMPLIANCE" "$issue_num" "$pr_num" --dry-run \
    --files-json "$per_pr_tmp/files.json" \
    --commits-json "$per_pr_tmp/commits.json" \
    --labels-json "$per_pr_tmp/labels.json" 2>/dev/null)"

  rm -rf "$per_pr_tmp"

  verdict="$(extract_tdd_verdict "$audit_out")"

  # Append the row to the accumulator.
  jq --argjson pr "$pr_num" \
     --arg path "$path_letter" \
     --arg verdict "$verdict" \
     --argjson issue "$issue_num" \
     '. += [{pr_number:$pr, path:$path, verdict:$verdict, issue_number:$issue}]' \
     "$ROWS_JSON_TMP" > "$ROWS_JSON_TMP.new" && mv "$ROWS_JSON_TMP.new" "$ROWS_JSON_TMP"
done < <(printf '%s' "$PR_LIST_JSON" | jq -c '.[]')

# --- stderr counters (mirror over-eval-report.sh shape) ---

if [ "$RELEASE_PR_COUNT" -gt 0 ]; then
  echo "compliance-backfill: $RELEASE_PR_COUNT release PRs excluded (autorelease label / release-please title rules)" >&2
fi
if [ "$SKIPPED_NO_LINK" -gt 0 ]; then
  echo "compliance-backfill: $SKIPPED_NO_LINK non-release PRs skipped for missing Closes/Fixes/Resolves marker — these are real misses worth fixing" >&2
fi

# --- output ---

if [ "$EMIT_ROWS_JSON" -eq 1 ]; then
  cat "$ROWS_JSON_TMP"
  exit 0
fi

# --- per-PATH aggregation + table render ---

emit_table() {
  local rows_json
  rows_json="$(cat "$ROWS_JSON_TMP")"

  # Aggregate per-PATH counts via jq.
  local agg_json
  agg_json="$(printf '%s' "$rows_json" | jq -c '
    reduce .[] as $r ({}; .[$r.path] = (
      (.[$r.path] // {N:0, PASS:0, WEAK:0, SKIP:0, "N/A":0, omitted:0}) as $b
      | $b
      | .N = $b.N + 1
      | .[$r.verdict] = ($b[$r.verdict] // 0) + 1
    ))
  ')"

  # Render one row per PATH letter (deterministic order A→D).
  local letter row_n row_pass row_weak row_skip row_na row_skip_rate denom
  for letter in A B C D; do
    row_n=$(printf '%s' "$agg_json" | jq -r --arg p "$letter" '.[$p].N // 0')
    if [ "$row_n" = "0" ]; then
      continue
    fi
    row_pass=$(printf '%s' "$agg_json" | jq -r --arg p "$letter" '.[$p].PASS // 0')
    row_weak=$(printf '%s' "$agg_json" | jq -r --arg p "$letter" '.[$p].WEAK // 0')
    row_skip=$(printf '%s' "$agg_json" | jq -r --arg p "$letter" '.[$p].SKIP // 0')
    row_na=$(printf '%s' "$agg_json" | jq -r --arg p "$letter" '.[$p]."N/A" // 0')

    denom=$((row_pass + row_weak + row_skip))
    if [ "$denom" -gt 0 ]; then
      row_skip_rate="$(awk -v s="$row_skip" -v d="$denom" 'BEGIN { printf "%.1f%%", (s/d) * 100 }')"
    else
      row_skip_rate="--"
    fi

    printf 'PATH %s | N=%s, PASS=%s, WEAK=%s, SKIP=%s, N/A=%s, SKIP-rate=%s\n' \
      "$letter" "$row_n" "$row_pass" "$row_weak" "$row_skip" "$row_na" "$row_skip_rate"
  done

  # Overall footer: SKIP-rate across all PASS+WEAK+SKIP rows (excludes N/A,
  # excludes PATH-A-omitted rows since they do not represent a TDD decision).
  local overall_pass overall_weak overall_skip overall_denom overall_rate
  overall_pass=$(printf '%s' "$rows_json" | jq '[.[] | select(.verdict == "PASS")] | length')
  overall_weak=$(printf '%s' "$rows_json" | jq '[.[] | select(.verdict == "WEAK")] | length')
  overall_skip=$(printf '%s' "$rows_json" | jq '[.[] | select(.verdict == "SKIP")] | length')
  overall_denom=$((overall_pass + overall_weak + overall_skip))
  if [ "$overall_denom" -gt 0 ]; then
    overall_rate="$(awk -v s="$overall_skip" -v d="$overall_denom" 'BEGIN { printf "%.1f%%", (s/d) * 100 }')"
  else
    overall_rate="--"
  fi
  printf '\nOverall SKIP-rate=%s (SKIP=%s, WEAK=%s / (PASS+WEAK+SKIP)=%s)\n' \
    "$overall_rate" "$overall_skip" "$overall_weak" "$overall_denom"
}

emit_table
