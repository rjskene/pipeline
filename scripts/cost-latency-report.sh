#!/bin/bash
set -uo pipefail
#
# cost-latency-report.sh — DOGFOOD-ONLY cost & latency report (issue #643).
#
# Joins the last N merged feature PRs in $PIPELINE_REPO with #642's capture
# JSONL (token + wall-clock records, one object per agent finish) to surface
# tokens / LOC / time per issue & stage, per-PATH and per-stage aggregates,
# TOP-N token consumers and slowest stages, and "over-served" outliers
# (full lifecycle ceremony spent on a tiny diff).
#
# This script is for this repo's own dogfood operation only. It is NOT
# shipped in the plugin manifest and writes nothing under
# ${CLAUDE_PLUGIN_ROOT}. The only consumer-owned path it touches is the
# gated `.claude/logs/` capture log it READS (resolved via $CAPTURE_LOG,
# default .claude/logs/agent-costs.jsonl) — already on the runtime
# allow-list per CLAUDE.md "Namespace discipline". It consumes #642's
# capture layer; if that file is absent/empty the report degrades
# gracefully (all token/duration cells render `--`), never errors.
#
# Usage:
#   bash scripts/cost-latency-report.sh                       # live (calls gh)
#   bash scripts/cost-latency-report.sh --limit 100           # window size
#   bash scripts/cost-latency-report.sh --fixture <dir>       # fixture mode
#   bash scripts/cost-latency-report.sh --dry-run             # list PRs only
#   bash scripts/cost-latency-report.sh --emit-rows-json      # debug: rows-as-JSON
#   bash scripts/cost-latency-report.sh --over-served-loc 20  # over-served LOC threshold
#   bash scripts/cost-latency-report.sh --top-n 5             # TOP-N list size
#   bash scripts/cost-latency-report.sh --capture-log PATH    # override capture JSONL path
#   bash scripts/cost-latency-report.sh --help
#

LIMIT=50
FIXTURE_DIR=""
DRY_RUN=0
EMIT_ROWS_JSON=0
OVER_SERVED_LOC=20
TOPN=5
CAPTURE_LOG=""

print_usage() {
  cat <<'USAGE'
Usage: cost-latency-report.sh [--limit N] [--fixture DIR] [--dry-run]
                              [--emit-rows-json] [--over-served-loc N]
                              [--top-n N] [--capture-log PATH] [--help]

  cost-latency-report.sh — DOGFOOD-ONLY cost & latency report.

  Joins merged feature PRs with #642's capture JSONL (tokens + wall-clock)
  to report tokens/LOC/time per issue & stage, per-PATH/per-stage
  aggregates, TOP-N consumers, and over-served outliers.

  --limit N            Number of most-recent merged PRs to walk (default: 50).
  --fixture DIR        Read prs.json / pr-<N>.json / issue-<N>.json /
                       capture.jsonl from DIR instead of calling `gh`.
                       Used by the test suite.
  --dry-run            Fetch the PR list, print "would-fetch: PR #<N>" for
                       each eligible feature PR, and exit without rendering.
  --emit-rows-json     Debug: emit the per-issue rows as a JSON array to
                       stdout instead of the formatted tables.
  --over-served-loc N  LOC threshold below which a full-ceremony issue is
                       flagged over-served (default: 20).
  --top-n N            Size of the TOP-N consumer / slowest-stage lists
                       (default: 5).
  --capture-log PATH   Override the live capture JSONL path (default
                       .claude/logs/agent-costs.jsonl). Ignored in fixture mode.
  --help               Print this banner and exit 0.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)            print_usage; exit 0 ;;
    --limit)              LIMIT="${2:-}"; shift 2 ;;
    --limit=*)            LIMIT="${1#--limit=}"; shift ;;
    --fixture)            FIXTURE_DIR="${2:-}"; shift 2 ;;
    --fixture=*)          FIXTURE_DIR="${1#--fixture=}"; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --emit-rows-json)     EMIT_ROWS_JSON=1; shift ;;
    --over-served-loc)    OVER_SERVED_LOC="${2:-}"; shift 2 ;;
    --over-served-loc=*)  OVER_SERVED_LOC="${1#--over-served-loc=}"; shift ;;
    --top-n)              TOPN="${2:-}"; shift 2 ;;
    --top-n=*)            TOPN="${1#--top-n=}"; shift ;;
    --capture-log)        CAPTURE_LOG="${2:-}"; shift 2 ;;
    --capture-log=*)      CAPTURE_LOG="${1#--capture-log=}"; shift ;;
    *)
      echo "cost-latency-report: ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- I/O helpers (fixture-aware) ---

# load_pr_list — print the merged-PR list as a JSON array of objects with at
# least {number, title, additions, deletions, body, mergedAt, labels}. Fixture
# mode reads prs.json; live mode calls `gh pr list ... --json ...`.
load_pr_list() {
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/prs.json" ]; then
      echo "cost-latency-report: ERROR: fixture prs.json not found at $FIXTURE_DIR/prs.json" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/prs.json"
  else
    if [ -z "${PIPELINE_REPO:-}" ]; then
      echo "cost-latency-report: ERROR: PIPELINE_REPO not set" >&2
      return 1
    fi
    gh pr list \
      --repo "$PIPELINE_REPO" \
      --state merged \
      --limit "$LIMIT" \
      --json number,title,additions,deletions,body,mergedAt,labels
  fi
}

# RELEASE_PR_JQ — jq filter selecting ONLY release PRs (any rule matches →
# release). Copied verbatim from over-eval-report.sh so the eligible-PR
# population matches the sibling reports (issue #500). Rules (OR-combined):
#   - any label .name in {"autorelease: tagged", "autorelease: pending"}
#   - .title matches ^chore\(main\): release   (release-please autorelease)
#   - .title matches ^release: v               (back-sync convention)
#   - .title matches ^chore\(release\):        (manual release housekeeping)
RELEASE_PR_JQ='(
  ((.labels // []) | any(.name == "autorelease: tagged" or .name == "autorelease: pending"))
  or ((.title // "") | test("^chore\\(main\\): release"))
  or ((.title // "") | test("^release: v"))
  or ((.title // "") | test("^chore\\(release\\):"))
)'

# load_pr_view <num> — print the per-PR JSON payload including comments.
load_pr_view() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ ! -f "$FIXTURE_DIR/pr-$num.json" ]; then
      echo "cost-latency-report: WARN: fixture pr-$num.json missing; skipping PR #$num" >&2
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
      echo "cost-latency-report: WARN: fixture issue-$num.json missing; skipping issue #$num" >&2
      return 1
    fi
    cat "$FIXTURE_DIR/issue-$num.json"
  else
    gh issue view "$num" \
      --repo "$PIPELINE_REPO" \
      --json number,labels,comments
  fi
}

# load_capture — print the #642 capture JSONL (one JSON object per line) for
# the report to read. Fixture mode reads DIR/capture.jsonl (empty string when
# absent). Live mode resolves $CAPTURE_LOG (default .claude/logs/agent-costs.jsonl,
# overridable by --capture-log) and cats it when present; emits empty otherwise
# so the report still works (all token/duration cells render `--`).
#
# This is the ONLY coupling point with #642's writer (merged via #653). Schema
# (schema_version=1, see scripts/capture-agent-costs.sh OUTPUT RECORD SCHEMA):
#   {"schema_version":1,"issue":"<string>","stage":"classify|plan|plan-eval|execute|pr-eval",
#    "tokens":{"input":<int>,"output":<int>,"cache_read":<int>,"cache_creation":<int>,"total":<int>},
#    "duration_ms":<int>}
# NOTE: #642 emits `issue` as a STRING and `tokens.total` = input+output+
# cache_read+cache_creation. Reads below coerce issue with `tostring` and sum
# `.tokens.total` (the all-in count). A #642 rename is a one-line CAPTURE_LOG change.
load_capture() {
  if [ -n "$FIXTURE_DIR" ]; then
    if [ -f "$FIXTURE_DIR/capture.jsonl" ]; then
      cat "$FIXTURE_DIR/capture.jsonl"
    fi
  else
    local path="${CAPTURE_LOG:-${REPO_ROOT}/.claude/logs/agent-costs.jsonl}"
    if [ -f "$path" ]; then
      cat "$path"
    fi
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

# has_block <comments-json> <heading> — emit 1 if any comment body contains a
# line starting with `## <heading>`, else 0. (Comment-shape ceremony signal,
# same heuristic the sibling reports rely on.)
has_block() {
  local comments="$1"
  local heading="$2"
  if printf '%s' "$comments" | jq -e --arg h "$heading" \
      'any(.[]; .body | test("(?m)^## " + ($h | gsub("[.\\\\+*?^$()\\[\\]{}|]"; "\\\\\\0"))))' \
      >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

# --- temp files ---
ROWS_TSV=$(mktemp)
trap 'rm -f "$ROWS_TSV"' EXIT

# --- load inputs ---

RAW_PR_LIST_JSON="$(load_pr_list)" || exit 1

# Capture JSONL → JSON array (parsed once, tolerantly). Each line is validated
# in isolation so a single malformed record (e.g. a torn final line from an
# in-progress append to the #642 log) is SKIPPED with a warning rather than
# silently zeroing the whole report. Empty / all-invalid input → empty array.
load_capture_array() {
  local line dropped=0
  local lines=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
      lines+=("$line")
    else
      dropped=$((dropped + 1))
    fi
  done < <(load_capture)
  if [ "$dropped" -gt 0 ]; then
    echo "cost-latency-report: WARN: skipped $dropped malformed capture line(s)" >&2
  fi
  if [ "${#lines[@]}" -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "${lines[@]}" | jq -cs '.'
  fi
}
CAPTURE_JSON="$(load_capture_array)"
[ -z "$CAPTURE_JSON" ] && CAPTURE_JSON='[]'

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

# --- main loop: iterate eligible PRs, emit one TSV row per linked issue ---
# Columns: issue<TAB>path<TAB>loc<TAB>ceremony<TAB>tokens_total<TAB>duration_ms<TAB>over_served<TAB>pr_num
# tokens_total / duration_ms are the literal string "null" when the issue has
# no capture records (distinct from a real 0).
SKIPPED_NO_LINK=0
while read -r pr; do
      pr_num=$(printf '%s' "$pr" | jq -r '.number')
      pr_body=$(printf '%s' "$pr" | jq -r '.body // ""')
      pr_additions=$(printf '%s' "$pr" | jq -r '.additions // 0')
      pr_deletions=$(printf '%s' "$pr" | jq -r '.deletions // 0')
      loc=$((pr_additions + pr_deletions))

      issue_num="$(extract_linked_issue "$pr_body")"
      if [ -z "$issue_num" ]; then
        SKIPPED_NO_LINK=$((SKIPPED_NO_LINK + 1))
        continue
      fi

      pr_view="$(load_pr_view "$pr_num" 2>/dev/null)" || continue
      issue_view="$(load_issue_view "$issue_num" 2>/dev/null)" || continue

      issue_labels="$(printf '%s' "$issue_view" | jq -c '.labels // []')"
      path="$(derive_path "$issue_labels")"

      issue_comments="$(printf '%s' "$issue_view" | jq -c '.comments // []')"
      pr_comments="$(printf '%s' "$pr_view"    | jq -c '.comments // []')"

      # ceremony = 1 iff issue has both ## Implementation Plan and ## Plan
      # Evaluation comments AND the PR has a ## Evaluation comment.
      has_plan="$(has_block "$issue_comments" "Implementation Plan")"
      has_plan_eval="$(has_block "$issue_comments" "Plan Evaluation")"
      has_pr_eval="$(has_block "$pr_comments" "Evaluation")"
      if [ "$has_plan" = "1" ] && [ "$has_plan_eval" = "1" ] && [ "$has_pr_eval" = "1" ]; then
        ceremony=1
      else
        ceremony=0
      fi

      # Sum tokens_total + duration_ms across ALL capture records for this issue.
      # No records → literal "null".
      sums="$(printf '%s' "$CAPTURE_JSON" | jq -c --arg n "$issue_num" '
        [.[] | select((.issue|tostring) == $n)] as $recs
        | if ($recs | length) == 0 then {tokens: null, dur: null}
          else {tokens: ([$recs[] | .tokens.total] | add),
                dur:    ([$recs[] | .duration_ms] | add)}
          end' 2>/dev/null)"
      tokens_total="$(printf '%s' "$sums" | jq -r '.tokens // "null"' 2>/dev/null)"
      duration_ms="$(printf '%s' "$sums" | jq -r '.dur // "null"' 2>/dev/null)"
      [ -z "$tokens_total" ] && tokens_total="null"
      [ -z "$duration_ms" ] && duration_ms="null"

      # over_served = ceremony AND loc <= OVER_SERVED_LOC.
      if [ "$ceremony" = "1" ] && [ "$loc" -le "$OVER_SERVED_LOC" ]; then
        over_served=1
      else
        over_served=0
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$issue_num" "$path" "$loc" "$ceremony" "$tokens_total" "$duration_ms" "$over_served" "$pr_num" \
        >> "$ROWS_TSV"
done < <(printf '%s' "$PR_LIST_JSON" | jq -c '.[]')

if [ "$SKIPPED_NO_LINK" -gt 0 ]; then
  echo "cost-latency-report: $SKIPPED_NO_LINK non-release PRs skipped for missing Closes/Fixes/Resolves marker" >&2
fi

# --- emit per-issue rows as JSON (debug / metrics-snapshot consumer) ---
emit_rows_json() {
  awk -F'\t' '
    BEGIN { print "[" }
    {
      if (NR > 1) print ",";
      issue=$1; path=$2; loc=$3; ceremony=$4; tt=$5; dur=$6; ov=$7; prn=$8;
      d = (loc > 0 ? loc : 1);
      if (tt == "null") { tt_j="null"; tpl="null" } else { tt_j=tt; tpl=sprintf("%.1f", tt / d) }
      if (dur == "null") { dur_j="null"; mpl="null" } else { dur_j=dur; mpl=sprintf("%.1f", dur / d) }
      printf "  {\"issue\":%s,\"path\":\"%s\",\"loc\":%s,\"ceremony\":%s,\"tokens_total\":%s,\"duration_ms\":%s,\"tokens_per_loc\":%s,\"ms_per_loc\":%s,\"over_served\":%s,\"pr_number\":%s}", \
        issue, path, loc, ceremony, tt_j, dur_j, tpl, mpl, ov, prn
    }
    END { print "\n]" }' "$ROWS_TSV"
}

if [ "$EMIT_ROWS_JSON" -eq 1 ]; then
  emit_rows_json
  exit 0
fi

# --- human table render ---

# In-window issue numbers (column 1 of the row TSV), as a JSON array — used to
# filter capture records into the per-stage aggregate.
INWINDOW_JSON="$(cut -f1 "$ROWS_TSV" | jq -R 'select(length>0)' 2>/dev/null | jq -cs '.' 2>/dev/null)"
[ -z "$INWINDOW_JSON" ] && INWINDOW_JSON='[]'

# Per-(issue,stage) capture sums for in-window issues:
#   issue<TAB>stage<TAB>tokens_sum<TAB>dur_sum   (one line per (issue,stage) group)
#
# Orchestrator records are session-scoped (issue == ""), so grouping them by
# [issue, stage] is degenerate (one all-time group). Partition the post-select
# stream: group orchestrator records by session_id (col1 = session_id, dur =
# null since post-#667 orchestrator duration_ms is always null), and keep inline
# stages grouped by (issue, stage). Concatenate so the @tsv 4-column contract
# (key \t stage \t tokens_sum \t dur_sum) consumed by emit_stage_table /
# emit_top_slow_stages (NF >= 4) is preserved.
STAGE_TSV="$(printf '%s' "$CAPTURE_JSON" | jq -r --argjson win "$INWINDOW_JSON" '
  [.[] | select(
      (.stage == "orchestrator" and .duration_ms == null)
      or ((.issue|tostring) as $i | $win | index($i))
    )] as $recs
  | (
      ($recs | map(select(.stage == "orchestrator")) | group_by(.session_id)
        | map([ (.[0].session_id // ""), "orchestrator",
                ([.[] | .tokens.total] | add), null ]))
      +
      ($recs | map(select(.stage != "orchestrator")) | group_by([(.issue|tostring), .stage])
        | map([ (.[0].issue|tostring), .[0].stage,
                ([.[] | .tokens.total] | add),
                ([.[] | .duration_ms] | add) ]))
    )
  | .[]
  | @tsv' 2>/dev/null)"

emit_banner() {
  local oldest newest
  oldest="$(printf '%s' "$PR_LIST_JSON" | jq -r '[.[].mergedAt // empty] | min // "?"')"
  newest="$(printf '%s' "$PR_LIST_JSON" | jq -r '[.[].mergedAt // empty] | max // "?"')"
  if [ "$RELEASE_PR_COUNT" -gt 0 ]; then
    printf 'COST/LATENCY REPORT — last %s feature PRs (window: %s to %s; %s release PRs excluded)\n\n' \
      "$PR_COUNT" "$oldest" "$newest" "$RELEASE_PR_COUNT"
  else
    printf 'COST/LATENCY REPORT — last %s feature PRs (window: %s to %s)\n\n' \
      "$PR_COUNT" "$oldest" "$newest"
  fi
}

# Per-PATH aggregate table. Medians for loc are over all rows in the PATH;
# token/duration/per-loc medians are over token-bearing rows only ('--' when
# the PATH has no token-bearing rows).
emit_path_table() {
  echo 'PATH | N  | median loc | median tokens | median dur(ms) | median tokens/loc | median ms/loc'
  sort -k2,2 "$ROWS_TSV" | awk -F'\t' '
    function median(arr, n,   i, j, tmp) {
      for (i=1; i<n; i++) for (j=i+1; j<=n; j++) if (arr[i] > arr[j]) { tmp=arr[i]; arr[i]=arr[j]; arr[j]=tmp }
      if (n == 0) return "";
      if (n % 2 == 1) return arr[(n+1)/2];
      return (arr[n/2] + arr[n/2+1]) / 2;
    }
    function fmt(v) {
      if (v == "") return "--";
      if (v == int(v)) return sprintf("%d", v);
      return sprintf("%.1f", v);
    }
    function flush(   lm) {
      if (cur == "") return;
      lm = median(locs, nrow);
      printf "%-4s | %-2d | %-10s | %-13s | %-14s | %-17s | %-13s\n", \
        cur, nrow, fmt(lm), \
        (ntok ? fmt(median(toks, ntok)) : "--"), \
        (ntok ? fmt(median(durs, ntok)) : "--"), \
        (ntok ? fmt(median(tpls, ntok)) : "--"), \
        (ntok ? fmt(median(mpls, ntok)) : "--");
      cur=""; nrow=0; ntok=0; delete locs; delete toks; delete durs; delete tpls; delete mpls;
    }
    { path=$2; if (path != cur) { flush(); cur=path }
      nrow++; locs[nrow]=$3;
      if ($5 != "null") { ntok++; toks[ntok]=$5; durs[ntok]=$6; d=($3>0?$3:1); tpls[ntok]=$5/d; mpls[ntok]=$6/d }
    }
    END { flush() }'
}

# Per-stage aggregate table over the 5 canonical stages. Median tokens/dur over
# the per-(issue,stage) sums; stages with no records render '--'.
emit_stage_table() {
  echo ""
  echo 'STAGE | N | median tokens | median dur(ms)'
  printf '%s\n' "$STAGE_TSV" | awk -F'\t' '
    function median(arr, n,   i, j, tmp) {
      for (i=1; i<n; i++) for (j=i+1; j<=n; j++) if (arr[i] > arr[j]) { tmp=arr[i]; arr[i]=arr[j]; arr[j]=tmp }
      if (n == 0) return "";
      if (n % 2 == 1) return arr[(n+1)/2];
      return (arr[n/2] + arr[n/2+1]) / 2;
    }
    function fmt(v) {
      if (v == "") return "--";
      if (v == int(v)) return sprintf("%d", v);
      return sprintf("%.1f", v);
    }
    NF >= 4 { s=$2; c[s]++; tk[s,c[s]]=$3; dr[s,c[s]]=$4 }
    END {
      m = split("classify plan plan-eval execute pr-eval orchestrator", order, " ");
      for (k=1; k<=m; k++) {
        s = order[k]; cnt = c[s] + 0;
        if (cnt == 0) { printf "%-9s | %-2d | %-13s | %-13s\n", s, 0, "--", "--"; continue }
        for (i=1; i<=cnt; i++) { tarr[i]=tk[s,i]; darr[i]=dr[s,i] }
        printf "%-9s | %-2d | %-13s | %-13s\n", s, cnt, fmt(median(tarr, cnt)), fmt(median(darr, cnt));
        delete tarr; delete darr;
      }
    }'
}

# TOP-N token consumers (per-issue), descending by tokens_total; null-token rows skipped.
emit_top_consumers() {
  echo ""
  echo "TOP-$TOPN TOKEN CONSUMERS:"
  awk -F'\t' '$5 != "null" { d=($3>0?$3:1); printf "%s\t%s\t%s\t%s\t%.1f\n", $5, $1, $2, $3, $5/d }' "$ROWS_TSV" \
    | sort -t "$(printf '\t')" -k1,1 -gr \
    | head -"$TOPN" \
    | awk -F'\t' '{ printf "issue #%s (PATH %s): %s tokens, %s LOC → %s/LOC\n", $2, $3, $1, $4, $5 }'
}

# TOP-N slowest stages, descending by summed duration_ms per (issue,stage).
emit_top_slow_stages() {
  echo ""
  echo "TOP-$TOPN SLOWEST STAGES:"
  printf '%s\n' "$STAGE_TSV" | awk -F'\t' 'NF >= 4 { printf "%s\t%s\t%s\n", $4, $1, $2 }' \
    | sort -t "$(printf '\t')" -k1,1 -gr \
    | head -"$TOPN" \
    | awk -F'\t' '{ printf "issue #%s / %s: %s ms\n", $2, $3, $1 }'
}

# Over-served outliers: every row with over_served == 1.
emit_over_served() {
  echo ""
  echo "OVER-SERVED OUTLIERS:"
  while IFS=$'\t' read -r issue path loc ceremony tt dur ov prn; do
    [ -z "$issue" ] && continue
    if [ "$ov" = "1" ]; then
      printf "issue #%s (PATH %s): %s LOC, full ceremony → should've been TDD/hotfix\n" "$issue" "$path" "$loc"
    fi
  done < "$ROWS_TSV"
}

emit_banner
emit_path_table
emit_stage_table
emit_top_consumers
emit_top_slow_stages
emit_over_served
