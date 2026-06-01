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
EMIT_PRICING_JSON=0
TOKENOMICS=0
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
  --emit-pricing-json  Debug: emit aggregate pricing as JSON
                       {priced_cost_usd, unpriced_count} and exit. Prices each
                       capture record from per-model rate env vars (Opus default
                       fallback); model=="" records are UNPRICED (excluded from
                       the $ total, counted separately). See PRICING below.
  --tokenomics         Emit ADDITIONAL cost-analysis tables (per-bucket
                       token-share vs cost-share, per-stage cost, spawn vs
                       in-session structure + stage×structure cross-tab, and a
                       net-of-cache_read "size" view). Default output is
                       unchanged when this flag is absent.
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
    --emit-pricing-json)  EMIT_PRICING_JSON=1; shift ;;
    --tokenomics)         TOKENOMICS=1; shift ;;
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

# --- pricing (issue #721) ---
#
# Per-model token pricing, config-driven. Rates are USD per 1,000,000 tokens,
# one per bucket {input, output, cache_creation, cache_read}, read from env vars
#
#     PIPELINE_PRICE_<MODEL>_INPUT
#     PIPELINE_PRICE_<MODEL>_OUTPUT
#     PIPELINE_PRICE_<MODEL>_CACHE_CREATION
#     PIPELINE_PRICE_<MODEL>_CACHE_READ
#
# where <MODEL> is the record's `model` string NORMALIZED: upcased, then every
# run of non-alphanumeric chars collapsed to a single underscore (e.g.
# "claude-opus-4-8" → "CLAUDE_OPUS_4_8"). The script runs after pipeline.config
# is sourced by the skill, so these are ambient env; in fixture/test mode they
# are typically unset and the per-model baked DEFAULT list price applies per
# bucket (per 1M tokens, #733):
#   Opus 4.8:   input 15, output 75, cache_creation 18.75, cache_read 1.50
#   Sonnet 4.6: input  3, output 15, cache_creation  3.75, cache_read 0.30
#   Haiku 4.5:  input  1, output  5, cache_creation  1.25, cache_read 0.10
# An UNKNOWN model falls back EXPLICITLY to the Opus rates — a conservative
# upper-bound over-estimate (better than under-counting an unrecognized model).
#
# Cost(record) = Σ_bucket (tokens_bucket / 1e6 * rate_bucket), summed across
# records for aggregates. Records with model=="" (or model absent) are UNPRICED
# (#699 INLINE records): they are NOT priced, are EXCLUDED from the $ total, and
# are COUNTED so coverage health is visible — never silently dropped.

# price_model_normalize <model-string> — upcase + non-alnum runs → single '_'.
price_model_normalize() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g'
}

# price_default <normalized-model> <BUCKET> — echo the baked per-1M list-price
# default for (model, bucket). Known models price at their own published rates;
# unknown models fall back EXPLICITLY to Opus (conservative upper bound).
# BUCKET is one of INPUT|OUTPUT|CACHE_CREATION|CACHE_READ.
price_default() {
  local norm="$1" bucket="$2"
  case "$norm" in
    CLAUDE_OPUS_4_8)
      case "$bucket" in
        INPUT) printf '15' ;; OUTPUT) printf '75' ;;
        CACHE_CREATION) printf '18.75' ;; CACHE_READ) printf '1.50' ;;
      esac ;;
    CLAUDE_SONNET_4_6)
      case "$bucket" in
        INPUT) printf '3' ;; OUTPUT) printf '15' ;;
        CACHE_CREATION) printf '3.75' ;; CACHE_READ) printf '0.30' ;;
      esac ;;
    CLAUDE_HAIKU_4_5)
      case "$bucket" in
        INPUT) printf '1' ;; OUTPUT) printf '5' ;;
        CACHE_CREATION) printf '1.25' ;; CACHE_READ) printf '0.10' ;;
      esac ;;
    *)
      # conservative upper-bound fallback for unknown models: Opus rates.
      case "$bucket" in
        INPUT) printf '15' ;; OUTPUT) printf '75' ;;
        CACHE_CREATION) printf '18.75' ;; CACHE_READ) printf '1.50' ;;
      esac ;;
  esac
}

# price_rate <normalized-model> <BUCKET> — echo the configured per-1M rate for
# (model, bucket) via ${!var} indirection, falling back to the per-model baked
# default. BUCKET is one of INPUT|OUTPUT|CACHE_CREATION|CACHE_READ.
price_rate() {
  local norm="$1" bucket="$2"
  local var="PIPELINE_PRICE_${norm}_${bucket}"
  local val="${!var:-}"
  if [ -n "$val" ]; then
    printf '%s' "$val"
  else
    price_default "$norm" "$bucket"
  fi
}

# compute_pricing — read CAPTURE_JSON, return "<priced_cost_usd> <unpriced_count>"
# (space-separated). priced_cost_usd is formatted to 2 decimals. Unpriced
# (model=="" or absent) records are excluded from the cost but counted.
compute_pricing() {
  local total="0" unpriced=0
  local line model norm
  local r_in r_out r_cc r_cr
  # Iterate one record per line so per-record model lookup + ${!var} indirection
  # happens in bash; float arithmetic is delegated to awk per record.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    model="$(printf '%s' "$line" | jq -r '.model // ""' 2>/dev/null)"
    if [ -z "$model" ] || [ "$model" = "null" ]; then
      unpriced=$((unpriced + 1))
      continue
    fi
    norm="$(price_model_normalize "$model")"
    r_in="$(price_rate "$norm" INPUT)"
    r_out="$(price_rate "$norm" OUTPUT)"
    r_cc="$(price_rate "$norm" CACHE_CREATION)"
    r_cr="$(price_rate "$norm" CACHE_READ)"
    total="$(printf '%s' "$line" | jq -r '
        .tokens // {} | [(.input//0),(.output//0),(.cache_creation//0),(.cache_read//0)] | @tsv' 2>/dev/null \
      | awk -v t="$total" -v ri="$r_in" -v ro="$r_out" -v rcc="$r_cc" -v rcr="$r_cr" -F'\t' '
          { t += ($1/1e6)*ri + ($2/1e6)*ro + ($3/1e6)*rcc + ($4/1e6)*rcr }
          END { printf "%.10f", t }')"
  done < <(printf '%s' "$CAPTURE_JSON" | jq -c '.[]' 2>/dev/null)
  printf '%s %s' "$(awk -v t="$total" 'BEGIN { printf "%.2f", t }')" "$unpriced"
}

# priced_records_tsv — emit one TSV line per PRICED capture record (model!=""):
#   stage <TAB> agent_kind <TAB> tok_in <TAB> tok_out <TAB> tok_cc <TAB> tok_cr <TAB>
#   cost_in <TAB> cost_out <TAB> cost_cc <TAB> cost_cr
# tokens are the raw bucket counts; cost_* are the per-bucket USD for that record
# at the resolved per-(model,bucket) rate (Opus default fallback). Unpriced
# (model=="") records are SKIPPED here — token totals for the tokenomics tables
# are intentionally over PRICED records, since the $ columns are only meaningful
# where a rate applies. This is the shared substrate for the --tokenomics tables.
priced_records_tsv() {
  local line model norm
  local r_in r_out r_cc r_cr
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    model="$(printf '%s' "$line" | jq -r '.model // ""' 2>/dev/null)"
    if [ -z "$model" ] || [ "$model" = "null" ]; then
      continue
    fi
    norm="$(price_model_normalize "$model")"
    r_in="$(price_rate "$norm" INPUT)"
    r_out="$(price_rate "$norm" OUTPUT)"
    r_cc="$(price_rate "$norm" CACHE_CREATION)"
    r_cr="$(price_rate "$norm" CACHE_READ)"
    printf '%s' "$line" | jq -r '
        [ (.stage // ""), (.agent_kind // ""),
          (.tokens.input//0), (.tokens.output//0),
          (.tokens.cache_creation//0), (.tokens.cache_read//0) ] | @tsv' 2>/dev/null \
      | awk -F'\t' -v ri="$r_in" -v ro="$r_out" -v rcc="$r_cc" -v rcr="$r_cr" 'BEGIN{OFS="\t"} {
          ci=($3/1e6)*ri; co=($4/1e6)*ro; cc=($5/1e6)*rcc; cr=($6/1e6)*rcr;
          print $1,$2,$3,$4,$5,$6,ci,co,cc,cr
        }'
  done < <(printf '%s' "$CAPTURE_JSON" | jq -c '.[]' 2>/dev/null)
}

# priced_issue_stage_cost_tsv — emit one TSV line per PRICED capture record
# (model!="") as:
#   issue <TAB> stage <TAB> cost_usd <TAB> input <TAB> output <TAB> cache_read
# cost_usd is the all-four-bucket USD for that record at the resolved per-(model,
# bucket) rate (Opus default fallback). Unpriced (model=="") records are SKIPPED.
# input/output/cache_read are the raw token counts (append-only, for the per-PR
# trend table's token columns); the breakeven consumer reads only $1/$2/$3.
# Shared substrate for the per-issue --tokenomics tables (B→D breakeven) that
# need issue+stage attribution, which priced_records_tsv (stage-only) lacks.
priced_issue_stage_cost_tsv() {
  local line model norm
  local r_in r_out r_cc r_cr
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    model="$(printf '%s' "$line" | jq -r '.model // ""' 2>/dev/null)"
    if [ -z "$model" ] || [ "$model" = "null" ]; then
      continue
    fi
    norm="$(price_model_normalize "$model")"
    r_in="$(price_rate "$norm" INPUT)"
    r_out="$(price_rate "$norm" OUTPUT)"
    r_cc="$(price_rate "$norm" CACHE_CREATION)"
    r_cr="$(price_rate "$norm" CACHE_READ)"
    printf '%s' "$line" | jq -r '
        [ (.issue // "" | tostring), (.stage // ""),
          (.tokens.input//0), (.tokens.output//0),
          (.tokens.cache_creation//0), (.tokens.cache_read//0) ] | @tsv' 2>/dev/null \
      | awk -F'\t' -v ri="$r_in" -v ro="$r_out" -v rcc="$r_cc" -v rcr="$r_cr" 'BEGIN{OFS="\t"} {
          c=($3/1e6)*ri + ($4/1e6)*ro + ($5/1e6)*rcc + ($6/1e6)*rcr;
          # APPEND raw input/output/cache_read token counts (internal jq $3/$4/$6)
          # so CONSUMERS see: issue=$1 stage=$2 cost=$3 input=$4 output=$5 cache_read=$6
          printf "%s\t%s\t%.10f\t%d\t%d\t%d\n", $1, $2, c, $3, $4, $6
        }'
  done < <(printf '%s' "$CAPTURE_JSON" | jq -c '.[]' 2>/dev/null)
}

# priced_day_cost_tsv — emit one TSV line per PRICED capture record (model!="")
# whose ts_start has a YYYY-MM-DD prefix:
#   date <TAB> cost_all <TAB> cost_output <TAB> input <TAB> output <TAB> cache_read
# date is the YYYY-MM-DD prefix of ts_start; records with EMPTY/absent ts_start
# are SKIPPED (cannot be day-bucketed). cost_all is the all-four-bucket USD;
# cost_output is just the output-bucket USD (for the output%-of-cost column).
# input/output/cache_read are the raw token counts (append-only, for the trend
# table's per-day token columns).
# Shared substrate for the --tokenomics per-day trend table.
priced_day_cost_tsv() {
  local line model norm day
  local r_in r_out r_cc r_cr
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    model="$(printf '%s' "$line" | jq -r '.model // ""' 2>/dev/null)"
    if [ -z "$model" ] || [ "$model" = "null" ]; then
      continue
    fi
    # YYYY-MM-DD prefix of ts_start; skip empty/absent.
    day="$(printf '%s' "$line" | jq -r '(.ts_start // "")' 2>/dev/null | cut -c1-10)"
    if [ -z "$day" ] || ! printf '%s' "$day" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      continue
    fi
    norm="$(price_model_normalize "$model")"
    r_in="$(price_rate "$norm" INPUT)"
    r_out="$(price_rate "$norm" OUTPUT)"
    r_cc="$(price_rate "$norm" CACHE_CREATION)"
    r_cr="$(price_rate "$norm" CACHE_READ)"
    printf '%s' "$line" | jq -r '
        [ (.tokens.input//0), (.tokens.output//0),
          (.tokens.cache_creation//0), (.tokens.cache_read//0) ] | @tsv' 2>/dev/null \
      | awk -F'\t' -v d="$day" -v ri="$r_in" -v ro="$r_out" -v rcc="$r_cc" -v rcr="$r_cr" 'BEGIN{OFS="\t"} {
          call=($1/1e6)*ri + ($2/1e6)*ro + ($3/1e6)*rcc + ($4/1e6)*rcr;
          cout=($2/1e6)*ro;
          # APPEND raw input/output/cache_read token counts (internal jq $1/$2/$4)
          # so CONSUMERS see: date=$1 cost_all=$2 cost_output=$3 input=$4 output=$5 cache_read=$6
          printf "%s\t%.10f\t%.10f\t%d\t%d\t%d\n", d, call, cout, $1, $2, $4
        }'
  done < <(printf '%s' "$CAPTURE_JSON" | jq -c '.[]' 2>/dev/null)
}

# priced_duration_tsv — emit one TSV line per PRICED capture record (model!="")
# with a numeric duration_ms:  agent_kind <TAB> stage <TAB> duration_ms
# Records with null/absent duration_ms are SKIPPED. Shared substrate for the
# --tokenomics task-latency aggregate (which must distinguish headless
# session-lifetime durations from in-session task latency).
priced_duration_tsv() {
  local line model
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    model="$(printf '%s' "$line" | jq -r '.model // ""' 2>/dev/null)"
    if [ -z "$model" ] || [ "$model" = "null" ]; then
      continue
    fi
    printf '%s' "$line" | jq -r '
        select((.duration_ms // null) != null)
        | [ (.agent_kind // ""), (.stage // ""), (.duration_ms) ] | @tsv' 2>/dev/null
  done < <(printf '%s' "$CAPTURE_JSON" | jq -c '.[]' 2>/dev/null)
}

# execute_headless_intervals_tsv — emit one TSV line per EXECUTE-stage headless
# capture record with BOTH a non-empty ts_start and ts_end:
#   start_epoch <TAB> end_epoch
# Timestamps are converted to epoch seconds via `date -d`; records with an empty/
# absent/unparseable ts_start or ts_end are SKIPPED (cannot bound an interval).
# Shared substrate for the --tokenomics concurrency assessment (interval-overlap
# sweep). Not gated on model — concurrency is a structural property of the
# headless worker fleet, independent of pricing coverage.
execute_headless_intervals_tsv() {
  local line ts_s ts_e ep_s ep_e
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ts_s="$(printf '%s' "$line" | jq -r '
        select((.stage // "") == "execute" and (.agent_kind // "") == "headless")
        | (.ts_start // "")' 2>/dev/null)"
    [ -z "$ts_s" ] && continue
    ts_e="$(printf '%s' "$line" | jq -r '(.ts_end // "")' 2>/dev/null)"
    [ -z "$ts_e" ] && continue
    ep_s="$(date -d "$ts_s" +%s 2>/dev/null)" || continue
    ep_e="$(date -d "$ts_e" +%s 2>/dev/null)" || continue
    [ -z "$ep_s" ] && continue
    [ -z "$ep_e" ] && continue
    printf '%s\t%s\n' "$ep_s" "$ep_e"
  done < <(printf '%s' "$CAPTURE_JSON" | jq -c '.[]' 2>/dev/null)
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

# Dedup capture records on `record_key` (last-write-wins) ONCE at the source, so
# both downstream consumers — the per-issue sum (~l.326) and the per-stage
# STAGE_TSV aggregate (~l.391) — inherit it without re-implementing the dedup.
# `record_key` is a LOGICAL idempotency key: the same key denotes the same
# logical agent finish and may legitimately recur across appends with revised
# token totals; summing without deduping double-counts it (#698). Records with
# NO record_key are passed through untouched — each keyless record is its own
# group (they are NOT collapsed into a single "absent key" bucket), preserving
# every legacy keyless capture line.
CAPTURE_JSON="$(printf '%s' "$CAPTURE_JSON" | jq -c '
  ([ .[] | select(has("record_key") and .record_key != null) ]
     | group_by(.record_key) | map(.[-1]))
  + [ .[] | select((has("record_key") | not) or .record_key == null) ]
' 2>/dev/null)"
[ -z "$CAPTURE_JSON" ] && CAPTURE_JSON='[]'

# SECOND dedup pass: collapse records sharing the same (session_id, issue, stage)
# to the one with MAX tokens.total. This runs AFTER the record_key pass and
# folds the cases record_key alone cannot: retroactive-inline lower-bounds,
# duplicate captures, and N orchestrator cumulative snapshots of the SAME
# session (each a later, larger cumulative total) down to the final cumulative
# (max-total) figure. Records MISSING session_id (or null) are passed through
# UNTOUCHED — each is its own group (NOT collapsed by (null,issue,stage)),
# mirroring how the record_key pass partitions keyless records. DISTINCT
# session_ids for the same (issue,stage) are a genuine multi-session re-run and
# are preserved by group_by.
CAPTURE_JSON="$(printf '%s' "$CAPTURE_JSON" | jq -c '
  ([ .[] | select(has("session_id") and .session_id != null) ]
     | group_by(.session_id, .issue, .stage) | map(max_by(.tokens.total)))
  + [ .[] | select((has("session_id") | not) or .session_id == null) ]
' 2>/dev/null)"
[ -z "$CAPTURE_JSON" ] && CAPTURE_JSON='[]'

# --- emit aggregate pricing as JSON (debug; feeds Task-3 tokenomics) ---
if [ "$EMIT_PRICING_JSON" -eq 1 ]; then
  read -r _priced_cost _unpriced_count < <(compute_pricing)
  jq -cn --arg cost "$_priced_cost" --argjson unpriced "${_unpriced_count:-0}" \
    '{priced_cost_usd: $cost, unpriced_count: $unpriced}'
  exit 0
fi

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
#   issue<TAB>stage<TAB>tokens_sum<TAB>dur_sum<TAB>input<TAB>output<TAB>cache_creation<TAB>cache_read
#   (one line per (issue,stage) group)
#
# Orchestrator records are session-scoped (issue == ""), so grouping them by
# [issue, stage] is degenerate (one all-time group). Partition the post-select
# stream: group orchestrator records by session_id (col1 = session_id, dur =
# null since post-#667 orchestrator duration_ms is always null), and keep inline
# stages grouped by (issue, stage). Concatenate so the @tsv contract consumed by
# emit_stage_table / emit_top_slow_stages (NF >= 4) is preserved.
#
# The four per-bucket token sums (cols 5-8) are over ALL records in the group
# (priced + unpriced — neither model- nor interval-gated), so an UNPRICED
# (model="") stage still shows REAL per-bucket token counts (#789). They mirror
# the all-records substrate emit_path_size_table uses.
STAGE_TSV="$(printf '%s' "$CAPTURE_JSON" | jq -r --argjson win "$INWINDOW_JSON" '
  [.[] | select(
      (.stage == "orchestrator" and .duration_ms == null)
      or ((.issue|tostring) as $i | $win | index($i))
    )] as $recs
  | (
      ($recs | map(select(.stage == "orchestrator")) | group_by(.session_id)
        | map([ (.[0].session_id // ""), "orchestrator",
                ([.[] | .tokens.total] | add), null,
                ([.[] | (.tokens.input//0)] | add),
                ([.[] | (.tokens.output//0)] | add),
                ([.[] | (.tokens.cache_creation//0)] | add),
                ([.[] | (.tokens.cache_read//0)] | add) ]))
      +
      ($recs | map(select(.stage != "orchestrator")) | group_by([(.issue|tostring), .stage])
        | map([ (.[0].issue|tostring), .[0].stage,
                ([.[] | .tokens.total] | add),
                ([.[] | .duration_ms] | add),
                ([.[] | (.tokens.input//0)] | add),
                ([.[] | (.tokens.output//0)] | add),
                ([.[] | (.tokens.cache_creation//0)] | add),
                ([.[] | (.tokens.cache_read//0)] | add) ]))
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
  echo 'PATH | N  | median loc | median tokens | median dur(min) | median tokens/loc | median ms/loc'
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
    # min_fmt(ms) — render a raw ms duration in MINUTES (ms/60000, 1dp); "" → "--".
    function min_fmt(v) { if (v == "") return "--"; return sprintf("%.1f", v/60000) }
    function flush(   lm) {
      if (cur == "") return;
      lm = median(locs, nrow);
      printf "%-4s | %-2d | %-10s | %-13s | %-15s | %-17s | %-13s\n", \
        cur, nrow, fmt(lm), \
        (ntok ? fmt(median(toks, ntok)) : "--"), \
        (ntok ? min_fmt(median(durs, ntok)) : "--"), \
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
  echo 'STAGE | N | median tokens | median dur(min) | input | output | cache_creation | cache_read'
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
    # min_fmt(ms) — render a raw ms duration in MINUTES (ms/60000, 1dp); "" → "--".
    function min_fmt(v) { if (v == "") return "--"; return sprintf("%.1f", v/60000) }
    NF >= 4 { s=$2; c[s]++; tk[s,c[s]]=$3; dr[s,c[s]]=$4;
              bin[s,c[s]]=$5+0; bout[s,c[s]]=$6+0; bcc[s,c[s]]=$7+0; bcr[s,c[s]]=$8+0 }
    END {
      m = split("classify plan plan-eval execute pr-eval orchestrator", order, " ");
      for (k=1; k<=m; k++) {
        s = order[k]; cnt = c[s] + 0;
        # orchestrator tokens.total EXCLUDES cache_read while inline-stage totals
        # include it (#668); the two are not directly comparable, so flag it.
        note = (s == "orchestrator" && cnt > 0) ? "  (tokens excl. cache_read, #668)" : "";
        if (cnt == 0) { printf "%-9s | %-2d | %-13s | %-15s | %12s | %12s | %14s | %12s%s\n", s, 0, "--", "--", "--", "--", "--", "--", note; continue }
        for (i=1; i<=cnt; i++) { tarr[i]=tk[s,i]; darr[i]=dr[s,i]; iarr[i]=bin[s,i]; oarr[i]=bout[s,i]; carr[i]=bcc[s,i]; rarr[i]=bcr[s,i] }
        printf "%-9s | %-2d | %-13s | %-15s | %12d | %12d | %14d | %12d%s\n", \
          s, cnt, fmt(median(tarr, cnt)), min_fmt(median(darr, cnt)), \
          median(iarr, cnt), median(oarr, cnt), median(carr, cnt), median(rarr, cnt), note;
        delete tarr; delete darr; delete iarr; delete oarr; delete carr; delete rarr;
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
# Entries with a null/empty duration are excluded from this duration ranking —
# notably orchestrator rows, whose duration_ms is always null post-#667 and
# whose STAGE_TSV col1 is a session_id (not an issue number), so the `issue #`
# prefix would be misleading. They remain visible in the per-stage table.
emit_top_slow_stages() {
  echo ""
  echo "TOP-$TOPN SLOWEST STAGES:"
  printf '%s\n' "$STAGE_TSV" | awk -F'\t' 'NF >= 4 && $4 != "" { printf "%s\t%s\t%s\n", $4, $1, $2 }' \
    | sort -t "$(printf '\t')" -k1,1 -gr \
    | head -"$TOPN" \
    | awk -F'\t' '{ printf "issue #%s / %s: %.1f min\n", $2, $3, $1/60000 }'
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

# ============================================================================
# --tokenomics tables (issue #721). Each renders ONLY under --tokenomics; the
# default report above is byte-unchanged when the flag is absent. The $ columns
# price PRICED records (model!="") at the Opus-default-fallback per-bucket rate;
# unpriced (model=="") records contribute no cost. Float math via awk.
# ============================================================================
TOKENOMICS_TSV=""

# emit_bucket_table — per token bucket (input/output/cache_creation/cache_read):
# total tokens (over priced records), priced $, %-of-cost, and %-of-tokens. The
# headline finding: token-share != cost-share (output = low token-share / high
# cost-share at 75/1M; cache_read = high token-share / low cost-share at 1.50/1M).
emit_bucket_table() {
  echo ""
  echo 'BUCKET     | tokens       | $        | cost%  | token%'
  printf '%s\n' "$TOKENOMICS_TSV" | awk -F'\t' '
    NF >= 10 {
      tin+=$3; tout+=$4; tcc+=$5; tcr+=$6;
      cin+=$7; cout+=$8; ccc+=$9; ccr+=$10;
    }
    END {
      ttok = tin+tout+tcc+tcr;
      tcost = cin+cout+ccc+ccr;
      n = split("input output cache_creation cache_read", names, " ");
      tok[1]=tin; tok[2]=tout; tok[3]=tcc; tok[4]=tcr;
      cost[1]=cin; cost[2]=cout; cost[3]=ccc; cost[4]=ccr;
      for (i=1; i<=4; i++) {
        cp = (tcost>0 ? cost[i]/tcost*100 : 0);
        tp = (ttok>0  ? tok[i]/ttok*100  : 0);
        printf "%-10s | %12d | %8.2f | %5.1f%% | %5.1f%%\n", names[i], tok[i], cost[i], cp, tp;
      }
    }'
}

# emit_stage_cost_table — per stage (the 6 canonical stages): priced $ + cost
# share. The TOKEN column is a SIZE view that NETS OUT cache_read
# (tokens = input+output+cache_creation), so a cache-heavy stage like execute
# does not read as ~90% cache; the $ column uses ALL FOUR buckets (cache_read
# cost INCLUDED). Stages with no priced records render 0 / 0.00.
emit_stage_cost_table() {
  echo ""
  echo 'STAGE COST | size tokens  | $        | cost%'
  printf '%s\n' "$TOKENOMICS_TSV" | awk -F'\t' '
    NF >= 10 {
      s=$1;
      sz[s] += $3+$4+$5;                 # size view: input+output+cache_creation
      cost[s] += $7+$8+$9+$10;           # $ over all four buckets
      tcost += $7+$8+$9+$10;
    }
    END {
      m = split("classify plan plan-eval execute pr-eval orchestrator", order, " ");
      for (k=1; k<=m; k++) {
        s = order[k];
        cp = (tcost>0 ? cost[s]/tcost*100 : 0);
        printf "%-10s | %12d | %8.2f | %5.1f%%\n", s, (sz[s]+0), (cost[s]+0), cp;
      }
    }'
}

# structure_buckets_tsv — emit one TSV line per capture record (ALL records,
# priced + unpriced) keyed on STRUCTURE:
#   structure <TAB> input <TAB> output <TAB> cache_creation <TAB> cache_read
# structure is "spawn" (agent_kind=="headless") or "in-session" (else). NOT gated
# on model — this is the all-records substrate so an UNPRICED (model="") in-session
# row still shows REAL per-bucket token counts (#789), mirroring emit_path_size_table.
structure_buckets_tsv() {
  printf '%s' "$CAPTURE_JSON" | jq -r '
    .[]
    | [ (if (.agent_kind // "") == "headless" then "spawn" else "in-session" end),
        (.tokens.input//0), (.tokens.output//0),
        (.tokens.cache_creation//0), (.tokens.cache_read//0) ] | @tsv' 2>/dev/null
}

# emit_structure_table — structure dimension over BOTH substrates (#789):
#   spawn      = agent_kind == "headless"
#   in-session = agent_kind != "headless"  (inline + main/orchestrator)
# N + token-bucket columns source from structure_buckets_tsv (ALL records) so the
# in-session row shows REAL tokens even when unpriced; $ + cost% source from
# TOKENOMICS_TSV (PRICED records only — a rate is required for $). When a
# structure's priced cost is zero because ALL its records are unpriced, the $
# column renders '--' with an '(unpriced)' mark so a zero-cost row is never read
# as a zero-token row.
emit_structure_table() {
  echo ""
  echo 'STRUCTURE  | N  | input        | output       | cache_creation | cache_read   | $        | cost%'

  # Priced $ per structure (from TOKENOMICS_TSV: $2=agent_kind, $7..$10=cost).
  local priced_tsv
  priced_tsv="$(printf '%s\n' "$TOKENOMICS_TSV" | awk -F'\t' '
    NF >= 10 { st = ($2 == "headless") ? "spawn" : "in-session"; c[st] += $7+$8+$9+$10 }
    END { printf "spawn\t%.10f\nin-session\t%.10f\n", (c["spawn"]+0), (c["in-session"]+0) }')"

  printf '%s\n' "$(structure_buckets_tsv)" | awk -F'\t' -v priced="$priced_tsv" '
    BEGIN {
      np = split(priced, plines, "\n");
      for (i=1; i<=np; i++) { if (plines[i]=="") continue; split(plines[i], kv, "\t"); cost[kv[1]] = kv[2] }
    }
    $1 != "" {
      st=$1; n[st]++;
      tin[st]+=$2; tout[st]+=$3; tcc[st]+=$4; tcr[st]+=$5;
    }
    END {
      ntot = (n["spawn"]+0) + (n["in-session"]+0);
      tcost = (cost["spawn"]+0) + (cost["in-session"]+0);
      m = split("spawn in-session", order, " ");
      for (k=1; k<=m; k++) {
        st = order[k];
        c = cost[st] + 0;
        # $ renders "--" with an (unpriced) mark when this structure has records
        # but zero priced cost (all its records are unpriced — model="").
        if ((n[st]+0) > 0 && c == 0) {
          usd = "--"; cp = "  (unpriced)";
        } else {
          usd = sprintf("%8.2f", c);
          cp = sprintf(" | %5.1f%%", (tcost>0 ? c/tcost*100 : 0));
        }
        printf "%-10s | %-2d | %12d | %12d | %14d | %12d | %8s%s\n", \
          st, (n[st]+0), (tin[st]+0), (tout[st]+0), (tcc[st]+0), (tcr[st]+0), usd, cp;
      }
    }'
}

# emit_stage_structure_crosstab — stage × structure $ matrix: rows = the 6
# canonical stages, cols = {spawn, in-session}, cells = priced $ (all four
# buckets). Stages with no priced records render 0.00 / 0.00.
emit_stage_structure_crosstab() {
  echo ""
  echo 'STAGE x STRUCTURE | spawn $  | in-session $'
  printf '%s\n' "$TOKENOMICS_TSV" | awk -F'\t' '
    NF >= 10 {
      c = $7+$8+$9+$10;
      if ($2 == "headless") sp[$1] += c; else ins[$1] += c;
    }
    END {
      m = split("classify plan plan-eval execute pr-eval orchestrator", order, " ");
      for (k=1; k<=m; k++) {
        s = order[k];
        printf "%-17s | %8.2f | %12.2f\n", s, (sp[s]+0), (ins[s]+0);
      }
    }'
}

# emit_path_size_table — per-issue "size" view that NETS OUT cache_read for ALL
# rows (input+output+cache_creation), not just the orchestrator row (#668). The
# default emit_path_table above keeps cache_read INCLUDED and is byte-unchanged
# when --tokenomics is absent; this view is the cache-net companion. Size sums
# ALL capture records for the issue (priced + unpriced) — it is a token count,
# not a $ figure. Issues with no records render '--'.
emit_path_size_table() {
  echo ""
  echo 'PER-ISSUE SIZE | PATH | input | output | cache_read | net total'
  while IFS=$'\t' read -r issue path loc ceremony tt dur ov prn; do
    [ -z "$issue" ] && continue
    local cells tin tout tcr net
    # Four per-issue token sums over ALL records (priced + unpriced): it is a
    # token count, not a $ figure. net total nets OUT cache_read (input+output+
    # cache_creation), unchanged from the prior single-column value.
    cells="$(printf '%s' "$CAPTURE_JSON" | jq -r --arg n "$issue" '
      [.[] | select((.issue|tostring) == $n)] as $recs
      | if ($recs | length) == 0 then "--\t--\t--\t--"
        else
          ([$recs[] | (.tokens.input//0)] | add) as $tin
          | ([$recs[] | (.tokens.output//0)] | add) as $tout
          | ([$recs[] | (.tokens.cache_read//0)] | add) as $tcr
          | ([$recs[] | (.tokens.input//0)+(.tokens.output//0)+(.tokens.cache_creation//0)] | add) as $net
          | "\($tin)\t\($tout)\t\($tcr)\t\($net)"
        end' 2>/dev/null)"
    IFS=$'\t' read -r tin tout tcr net <<<"$cells"
    [ -z "$tin" ] && { tin="--"; tout="--"; tcr="--"; net="--"; }
    printf 'issue #%-20s | %-4s | %12s | %12s | %12s | %12s\n' "$issue" "$path" "$tin" "$tout" "$tcr" "$net"
  done < "$ROWS_TSV"
}

# emit_breakeven_table — B→D breakeven projection. For each PATH B issue
# in-window, model the savings if it had been routed PATH D instead. PATH D
# drops the plan + plan-eval ceremony stages and collapses execute to a single
# inline implementer (no separate plan/plan-eval token+latency).
#
# MODELLING ASSUMPTION (auditable): the "saved" amount is the issue's
# (plan + plan-eval) priced stage cost. Execute cost is assumed UNCHANGED under
# PATH D (a single inline implementer still does the execute work), so
# projected-D $ = current $ - (plan + plan-eval $). This intentionally ignores
# any second-order execute delta (PATH D may run a leaner execute); it is a
# first-order ceremony-elimination model, not a full re-simulation.
#
# Per-issue rows (issue, current $, projected-D $, savings) + an aggregate total.
emit_breakeven_table() {
  echo ""
  echo 'B→D BREAKEVEN | current $ | projected-D $ | savings $'
  # PATH B issues in-window (col2 == B) → one line per issue from ROWS_TSV.
  local pathb
  pathb="$(awk -F'\t' '$2 == "B" { print $1 }' "$ROWS_TSV")"
  # Per-(issue,stage) priced cost for the whole capture stream.
  local cost_tsv
  cost_tsv="$(priced_issue_stage_cost_tsv)"
  printf '%s\n' "$cost_tsv" | awk -F'\t' -v pathb="$pathb" '
    BEGIN {
      n = split(pathb, arr, "\n");
      for (i=1; i<=n; i++) if (arr[i] != "") isb[arr[i]] = 1;
    }
    {
      iss=$1; stage=$2; c=$3;
      if (!(iss in isb)) next;
      cur[iss] += c;
      if (stage == "plan" || stage == "plan-eval") saved[iss] += c;
    }
    END {
      tot_saved = 0;
      # Emit in a stable issue order.
      m = 0;
      for (k in cur) order[++m] = k;
      for (i=1; i<m; i++) for (j=i+1; j<=m; j++) if (order[i]+0 > order[j]+0) { t=order[i]; order[i]=order[j]; order[j]=t }
      for (i=1; i<=m; i++) {
        k = order[i];
        proj = cur[k] - saved[k];
        printf "issue #%-7s | %9.2f | %13.2f | %9.2f\n", k, cur[k], proj, saved[k];
        tot_saved += saved[k];
      }
      printf "%-14s | %9s | %13s | %9.2f\n", "TOTAL", "", "", tot_saved;
    }'
}

# emit_coverage_health — a single coverage-health block:
#   - execute-stage record N (over the deduped capture stream);
#   - % feature PRs joined = joined ÷ eligible, where eligible == PR_COUNT and
#     joined == PR_COUNT - SKIPPED_NO_LINK (PRs with a Closes/Fixes/Resolves link);
#   - model-attribution coverage % = priced records ÷ total records (a priced
#     record has a non-empty model; exposes #699 empty-model INLINE records);
#   - lower-bound (unreconciled) count = usage_complete:false records ÷ total —
#     inline sidecar/forward records whose subagent transcript was missing at
#     backfill time, so their totals are a LOWER BOUND, not the real cost (#773).
emit_coverage_health() {
  echo ""
  echo "COVERAGE HEALTH:"
  local exec_n total_n priced_n
  exec_n="$(printf '%s' "$CAPTURE_JSON" | jq -r '[.[] | select(.stage == "execute")] | length' 2>/dev/null)"
  total_n="$(printf '%s' "$CAPTURE_JSON" | jq -r 'length' 2>/dev/null)"
  priced_n="$(printf '%s' "$CAPTURE_JSON" | jq -r '[.[] | select((.model // "") != "")] | length' 2>/dev/null)"
  [ -z "$exec_n" ] && exec_n=0
  [ -z "$total_n" ] && total_n=0
  [ -z "$priced_n" ] && priced_n=0

  local eligible joined
  eligible="$PR_COUNT"
  joined=$((PR_COUNT - SKIPPED_NO_LINK))

  printf 'execute-stage records: %s\n' "$exec_n"
  awk -v j="$joined" -v e="$eligible" 'BEGIN {
    pct = (e > 0 ? j/e*100 : 0);
    printf "feature PRs joined: %d/%d (%.1f%%)\n", j, e, pct;
  }'
  awk -v p="$priced_n" -v t="$total_n" 'BEGIN {
    pct = (t > 0 ? p/t*100 : 0);
    printf "model-attribution coverage: %d/%d (%.1f%%)\n", p, t, pct;
  }'

  # Lower-bound (unreconciled) record count over the DEDUPED capture stream
  # (#773). usage_complete=false records are inline sidecar / forward lower
  # bounds whose subagent transcript was missing/pruned at backfill time; their
  # token totals read as a LOWER BOUND, not the real cost. Re-running the
  # capture backfill once the transcript exists reconciles them upward.
  local lb_n
  lb_n="$(printf '%s' "$CAPTURE_JSON" | jq -r '[.[] | select(.usage_complete == false)] | length' 2>/dev/null)"
  [ -z "$lb_n" ] && lb_n=0
  awk -v lb="$lb_n" -v t="$total_n" 'BEGIN {
    pct = (t > 0 ? lb/t*100 : 0);
    printf "lower-bound (unreconciled) records: %d/%d (%.1f%%) — these read as a LOWER BOUND; run the backfill to reconcile\n", lb, t, pct;
  }'
}

# emit_trend — per-day + per-PR $ trend with outlier flagging.
#
# Per-day: bucket PRICED records by date(ts_start) (YYYY-MM-DD prefix; records
# with empty ts_start are skipped upstream in priced_day_cost_tsv). Per day:
# total $, output $, output%-of-cost.
#
# OUTLIER THRESHOLD (documented): a day is flagged when its $ is >= 40% of the
# window total $. (Chosen over a mean-multiple rule because a single dominant
# day in a small window is exactly the signal we want to surface, and the
# 40%-of-window share is stable regardless of how many normal days surround it.)
#
# Per-PR: cost per merged feature PR via the existing PR→issue join (ROWS_TSV
# col1=issue, col8=pr_num), summing the per-(issue,stage) priced cost per issue.
emit_trend() {
  echo ""
  echo 'TREND (per-day) | input | output | cache_read | $ total  | $ output | output%-of-cost'
  printf '%s\n' "$(priced_day_cost_tsv)" | awk -F'\t' '
    { day=$1; if (day=="") next; tot[day]+=$2; out[day]+=$3; tin[day]+=$4; tout[day]+=$5; tcr[day]+=$6; grand+=$2 }
    END {
      n=0; for (d in tot) order[++n]=d;
      for (i=1;i<n;i++) for (j=i+1;j<=n;j++) if (order[i] > order[j]) { t=order[i]; order[i]=order[j]; order[j]=t }
      thresh = grand * 0.40;
      for (i=1;i<=n;i++) {
        d=order[i];
        op = (tot[d]>0 ? out[d]/tot[d]*100 : 0);
        flag = (tot[d] >= thresh && grand > 0) ? "  *OUTLIER" : "";
        printf "%-15s | %12d | %12d | %12d | %8.2f | %8.2f | %14.1f%%%s\n", d, tin[d], tout[d], tcr[d], tot[d], out[d], op, flag;
      }
    }'

  echo ""
  echo 'TREND (per-PR) | input | output | cache_read | $ total'
  # issue→pr map from ROWS_TSV (col1=issue, col8=pr_num).
  local issue_pr
  issue_pr="$(awk -F'\t' '{ print $1"\t"$8 }' "$ROWS_TSV")"
  local cost_tsv
  cost_tsv="$(priced_issue_stage_cost_tsv)"
  # Consumer fields: issue=$1 stage=$2 cost=$3 input=$4 output=$5 cache_read=$6.
  printf '%s\n' "$cost_tsv" | awk -F'\t' -v map="$issue_pr" '
    BEGIN {
      n=split(map, lines, "\n");
      for (i=1;i<=n;i++) { if (lines[i]=="") continue; split(lines[i], kv, "\t"); pr[kv[1]]=kv[2]; }
    }
    { iss=$1; if (!(iss in pr)) next; cost[pr[iss]] += $3; tin[pr[iss]] += $4; tout[pr[iss]] += $5; tcr[pr[iss]] += $6 }
    END {
      m=0; for (p in cost) order[++m]=p;
      for (i=1;i<m;i++) for (j=i+1;j<=m;j++) if (order[i]+0 > order[j]+0) { t=order[i]; order[i]=order[j]; order[j]=t }
      for (i=1;i<=m;i++) { p=order[i]; printf "PR #%-11s | %12d | %12d | %12d | %8.2f\n", p, tin[p], tout[p], tcr[p], cost[p]; }
    }'
}

# emit_latency_aggregate — task-latency view over PRICED records.
#
# Headless duration_ms is whole-session WALL-CLOCK (the ~5.4M ms cluster), NOT
# per-task latency: a headless worker's record spans its entire `claude -p`
# session, not the single task. So under --tokenomics we (1) list headless
# durations separately, annotated "(session-lifetime, not task-latency)", and
# (2) EXCLUDE headless durations from the task-latency median/aggregate, which
# is computed over IN-SESSION (agent_kind != "headless") records only. The
# default-path median dur(ms) rendering (emit_path_table/emit_stage_table) is
# untouched — this is an additive --tokenomics-only view.
emit_latency_aggregate() {
  local dur_tsv
  dur_tsv="$(priced_duration_tsv)"

  echo ""
  echo 'HEADLESS DURATIONS (session-lifetime, not task-latency):'
  printf '%s\n' "$dur_tsv" | awk -F'\t' '
    $1 == "headless" { printf "%-10s | %12d ms  (session-lifetime, not task-latency)\n", $2, $3 }'

  echo ""
  echo 'TASK LATENCY (in-session records only; headless excluded) | median dur(ms)'
  printf '%s\n' "$dur_tsv" | awk -F'\t' '
    function median(arr, n,   i, j, tmp) {
      for (i=1; i<n; i++) for (j=i+1; j<=n; j++) if (arr[i] > arr[j]) { tmp=arr[i]; arr[i]=arr[j]; arr[j]=tmp }
      if (n == 0) return "";
      if (n % 2 == 1) return arr[(n+1)/2];
      return (arr[n/2] + arr[n/2+1]) / 2;
    }
    function fmt(v) { if (v=="") return "--"; if (v==int(v)) return sprintf("%d", v); return sprintf("%.1f", v) }
    $1 != "headless" { d[++n]=$3 }
    END { printf "%-57s | %s\n", "median task latency", fmt(median(d, n)) }'
}

# emit_concurrency_assessment — data-derived execute-concurrency analysis (per
# docs/cost-architecture.md §8, the open empirical question this report owns).
#
# Observed: count overlapping [ts_start, ts_end] intervals among EXECUTE-stage
# headless worker records via a sweep-line (events sorted by epoch; +1 at start,
# -1 at end; running max). Reports the MAX observed concurrent execute count.
#
# Ceiling (TEXT): safe concurrency = min(rate-limit ceiling, cwd-isolation-safe
# count) — the tighter binds (cost-architecture.md §8 / §6). Surfaced as analysis
# text alongside the observed NUMBER so the operator can compare observed-vs-safe.
emit_concurrency_assessment() {
  echo ""
  echo "CONCURRENCY ASSESSMENT (execute-stage headless workers):"
  local intervals max_conc
  intervals="$(execute_headless_intervals_tsv)"
  max_conc="$(printf '%s\n' "$intervals" | awk -F'\t' '
    $1 != "" {
      ev[++n] = $1 "\t" "1";     # start event
      ev[++n] = $2 "\t" "-1";    # end event (quote the literal so awk does
                                 # not parse "\t" - 1 as arithmetic, which
                                 # dropped the tab+delta and broke the sweep)
    }
    END {
      # Sort events by epoch; on ties, process ENDS (-1) before STARTS (+1) so
      # touching-but-not-overlapping intervals are not counted as concurrent.
      for (i=1;i<n;i++) for (j=i+1;j<=n;j++) {
        split(ev[i], a, "\t"); split(ev[j], b, "\t");
        if (a[1] > b[1] || (a[1]==b[1] && a[2] > b[2])) { t=ev[i]; ev[i]=ev[j]; ev[j]=t }
      }
      cur=0; max=0;
      for (i=1;i<=n;i++) { split(ev[i], e, "\t"); cur += e[2]; if (cur > max) max=cur }
      print max+0;
    }')"
  [ -z "$max_conc" ] && max_conc=0
  printf 'max observed concurrent execute workers: %s\n' "$max_conc"
  echo 'ceiling = min(rate-limit ceiling, cwd-isolation-safe count) — the tighter binds'
  echo '  (per docs/cost-architecture.md §8: rate-limit = burst TPM + 5-hour rolling cap;'
  echo '   cwd-isolation = concurrent inline agents racing on shared git/fs state, #31940).'
  printf 'observed %s vs ceiling: see §8 for the empirical bind (TPM / rolling cap / cwd-isolation).\n' "$max_conc"
}

emit_banner
emit_path_table
emit_stage_table
emit_top_consumers
emit_top_slow_stages
emit_over_served

if [ "$TOKENOMICS" -eq 1 ]; then
  TOKENOMICS_TSV="$(priced_records_tsv)"
  emit_bucket_table
  emit_stage_cost_table
  emit_structure_table
  emit_stage_structure_crosstab
  emit_path_size_table
  emit_breakeven_table
  emit_coverage_health
  emit_trend
  emit_latency_aggregate
  emit_concurrency_assessment
fi
