#!/bin/bash
set -uo pipefail
#
# combine-hint-impact.sh — DOGFOOD-ONLY combine + path-hint impact report (#757).
#
# Measures the impact of the create-classify combine-heuristic + path-hint
# change (merged #752 at MERGE_TS) by partitioning GitHub issues into a `pre`
# (baseline) and `post` (treatment) cohort on issue createdAt vs MERGE_TS and
# comparing four metric families WITHIN `PATH × file-count` buckets:
#
#   1. Cost        — cache_creation + per-issue tokens, read from the gated
#                    agent-costs.jsonl capture log (joined by issue number).
#   2. Structural  — issues-created / mean files-per-issue / PR count /
#                    wave-serialization proxy, from GitHub.
#   3. Accuracy    — first-pass eval-approval rate + re-plan / escalation /
#                    fix-commit counts, mined from issue comments.
#   4. Hint quality — hint-emit rate + hint→classify agreement, POST-ONLY
#                    (no pre baseline possible).
#
# Verdict is a RECOMMENDATION ONLY (never auto-action). A min-N gate (default 5)
# refuses any verdict on tiny N → `INSUFFICIENT DATA`. This is the path the tool
# ships on TODAY: the post cohort is ~empty right after #752, so the only
# truthful verdict now is INSUFFICIENT DATA.
#
# This script is for this repo's own dogfood operation only. It is NOT shipped
# in the plugin manifest and writes nothing under ${CLAUDE_PLUGIN_ROOT}. The
# only consumer-owned path it touches is the gated `.claude/logs/` capture log
# it READS (resolved via $CAPTURE_LOG, default .claude/logs/agent-costs.jsonl) —
# already on the runtime allow-list per CLAUDE.md "Namespace discipline". It
# reads agent-costs.jsonl DIRECTLY (NOT the #642/#643 join). If that file is
# absent/empty the report degrades gracefully (token cells render `--`), never
# errors.
#
# NOTE: wave_serialization is a PROXY — the count of distinct issue
# creation-days per cohort, a coarse stand-in for scheduler-level
# serialization, not a precise metric.
#
# Usage:
#   bash scripts/combine-hint-impact.sh                     # live (gh + log)
#   bash scripts/combine-hint-impact.sh --fixture <dir>     # fixture mode
#   bash scripts/combine-hint-impact.sh --min-n 5           # verdict gate
#   bash scripts/combine-hint-impact.sh --merge-ts <ts>     # cohort split ts
#   bash scripts/combine-hint-impact.sh --emit-rows-json    # debug: rows JSON
#   bash scripts/combine-hint-impact.sh --emit-verdict-json # decision as JSON
#   bash scripts/combine-hint-impact.sh --help
#

LIMIT=50
FIXTURE_DIR=""
MERGE_TS="2026-06-01T10:32:15Z"
MIN_N=5
CAPTURE_LOG=""
EMIT_ROWS_JSON=0
EMIT_VERDICT_JSON=0

print_usage() {
  cat <<'USAGE'
Usage: combine-hint-impact.sh [--fixture DIR] [--merge-ts TS] [--min-n N]
                              [--capture-log PATH] [--limit N]
                              [--emit-rows-json] [--emit-verdict-json] [--help]

  combine-hint-impact.sh — DOGFOOD-ONLY combine + path-hint impact report.

  Partitions issues into pre/post cohorts on createdAt vs the #752 merge ts
  and compares cost / structural / accuracy / hint-quality WITHIN PATH ×
  file-count buckets. Emits a Keep / Revert-candidate recommendation, gated
  by a min-N threshold (INSUFFICIENT DATA below it). Recommendation only.

  --fixture DIR        Read issues.json / issue-<N>.json / capture.jsonl from
                       DIR instead of calling `gh` / the live capture log.
  --merge-ts TS        Cohort split timestamp (RFC-3339 Z). Default the #752
                       merge: 2026-06-01T10:32:15Z.
  --min-n N            Per-bucket / aggregate post-cohort min sample size for a
                       verdict (default 5). Below it → INSUFFICIENT DATA.
  --capture-log PATH   Override the agent-costs.jsonl path (live mode).
  --limit N            Number of most-recent issues to walk live (default 50).
  --emit-rows-json     Print per-issue rows as a JSON array (debug/test).
  --emit-verdict-json  Print the verdict decision as a JSON object (test).
  --help, -h           Print this help and exit.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help | -h) print_usage; exit 0 ;;
    --fixture) FIXTURE_DIR="${2:-}"; shift 2 ;;
    --fixture=*) FIXTURE_DIR="${1#*=}"; shift ;;
    --merge-ts) MERGE_TS="${2:-}"; shift 2 ;;
    --merge-ts=*) MERGE_TS="${1#*=}"; shift ;;
    --min-n) MIN_N="${2:-}"; shift 2 ;;
    --min-n=*) MIN_N="${1#*=}"; shift ;;
    --capture-log) CAPTURE_LOG="${2:-}"; shift 2 ;;
    --capture-log=*) CAPTURE_LOG="${1#*=}"; shift ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --limit=*) LIMIT="${1#*=}"; shift ;;
    --emit-rows-json) EMIT_ROWS_JSON=1; shift ;;
    --emit-verdict-json) EMIT_VERDICT_JSON=1; shift ;;
    *) echo "combine-hint-impact: ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- loaders ---------------------------------------------------------------

# load_issue_list — emit a JSON array of issues {number, createdAt, labels,
# title, body, files_changed?, wave?, pr?}. Fixture reads issues.json; live
# calls `gh issue list`.
load_issue_list() {
  if [ -n "$FIXTURE_DIR" ]; then
    cat "$FIXTURE_DIR/issues.json"
  else
    if [ -z "${PIPELINE_REPO:-}" ]; then
      echo "combine-hint-impact: ERROR: PIPELINE_REPO not set" >&2
      return 1
    fi
    gh issue list --repo "$PIPELINE_REPO" --state all --limit "$LIMIT" \
      --json number,createdAt,labels,title,body
  fi
}

# load_issue_view <num> — emit a single issue view {number, createdAt, labels,
# body, comments}. Fixture reads issue-<num>.json; live calls `gh issue view`.
load_issue_view() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ -f "$FIXTURE_DIR/issue-$num.json" ]; then
      cat "$FIXTURE_DIR/issue-$num.json"
    else
      echo "combine-hint-impact: WARN: fixture issue-$num.json missing" >&2
      return 1
    fi
  else
    gh issue view "$num" --repo "$PIPELINE_REPO" \
      --json number,createdAt,labels,body,comments
  fi
}

# load_capture — print the agent-costs.jsonl capture (one JSON object per line).
# Fixture reads DIR/capture.jsonl (empty when absent). Live resolves $CAPTURE_LOG
# (default .claude/logs/agent-costs.jsonl) and cats it when present; emits empty
# otherwise (graceful-degrade, never errors).
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

# derive_path <labels-json> — map issue labels to PATH letter (docs-only→A,
# quick-fix→D, multi-task→C, else B). Copied from cost-latency-report.sh.
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

# file_count_bucket <n> — map a files-changed count to a bucket label.
file_count_bucket() {
  local n="${1:-0}"
  [ -z "$n" ] && n=0
  if [ "$n" -le 1 ]; then echo "1"
  elif [ "$n" -le 3 ]; then echo "2-3"
  elif [ "$n" -le 6 ]; then echo "4-6"
  else echo "7+"; fi
}

# --- capture dedup ---------------------------------------------------------
# Two-pass dedup (copied from cost-latency-report.sh):
#  1. record_key last-write-wins (keyless records passed through untouched);
#  2. collapse (session_id, issue, stage) collisions to max_by(tokens.total).
CAPTURE_RAW="$(load_capture)"
if [ -n "$CAPTURE_RAW" ]; then
  CAPTURE_JSON="$(printf '%s\n' "$CAPTURE_RAW" | jq -s '.' 2>/dev/null || echo '[]')"
else
  CAPTURE_JSON="[]"
fi
CAPTURE_DEDUP="$(printf '%s' "$CAPTURE_JSON" | jq -c '
  ( [ .[] | select(has("record_key") and .record_key != null) ]
      | group_by(.record_key) | map(.[-1]) )
  + [ .[] | select((has("record_key") | not) or .record_key == null) ]
  | group_by(.session_id, .issue, .stage) | map(max_by(.tokens.total))
' 2>/dev/null || echo '[]')"

# per_issue_cache_creation <num> — sum tokens.cache_creation across deduped
# records for an issue. Echoes empty when no records (token cells render --).
per_issue_metric() {
  local num="$1" field="$2"
  printf '%s' "$CAPTURE_DEDUP" | jq -r --arg i "$num" --arg f "$field" \
    '[ .[] | select((.issue|tostring) == $i) | (.tokens[$f] // 0) ] | add // 0' 2>/dev/null
}

# --- accuracy comment mining -----------------------------------------------
# Returns "first_pass replan escalation fix" space-separated for one issue view.
mine_accuracy() {
  local view="$1"
  printf '%s' "$view" | jq -r '
    (.comments // []) as $c
    | (([ $c[] | select(.body | test("## Implementation Plan")) ] | length) - 1) as $replan_raw
    | (if $replan_raw < 0 then 0 else $replan_raw end) as $replan
    | ([ $c[] | select(.body | test("(?i)## (Plan )?Evaluation")) | select(.body | test("(?i)approv")) ] | length) as $approved
    | (if ($approved > 0 and $replan == 0) then 1 else 0 end) as $first_pass
    | ([ $c[] | select(.body | test("(?i)(B↔D|escalat|re-?classif)")) ] | length) as $escalation
    | ([ $c[] | select(.body | test("(?i)(^|\\s)(fix:|fixup)")) ] | length) as $fix
    | "\($first_pass) \($replan) \($escalation) \($fix)"
  ' 2>/dev/null
}

# parse_hint <body> — emit the uppercased path-hint letter from a body, or empty.
parse_hint() {
  printf '%s' "$1" | grep -oiE '<!--[[:space:]]*pipeline:path-hint=[A-Ca-c][[:space:]]*-->' \
    | grep -oiE 'path-hint=[A-Ca-c]' | grep -oiE '[A-Ca-c]$' | head -1 | tr '[:lower:]' '[:upper:]'
}

# parse_classify_path <view> — emit recommended_path letter from a ## Classification comment.
parse_classify_path() {
  printf '%s' "$1" | jq -r '(.comments // [])[].body' 2>/dev/null \
    | grep -oiE 'recommended_path:\*\* [ABC]' | grep -oiE '[ABC]$' | head -1 | tr '[:lower:]' '[:upper:]'
}

# --- build per-issue rows --------------------------------------------------
ISSUES_JSON="$(load_issue_list)"
ROWS_JSON="[]"

# iterate over issues
ISSUE_NUMS="$(printf '%s' "$ISSUES_JSON" | jq -r '.[].number')"
for num in $ISSUE_NUMS; do
  meta="$(printf '%s' "$ISSUES_JSON" | jq -c --argjson n "$num" '.[] | select(.number == $n)')"
  created="$(printf '%s' "$meta" | jq -r '.createdAt')"
  labels="$(printf '%s' "$meta" | jq -c '.labels // []')"
  body="$(printf '%s' "$meta" | jq -r '.body // ""')"
  files_changed="$(printf '%s' "$meta" | jq -r '.files_changed // 0')"
  wave="$(printf '%s' "$meta" | jq -r '.wave // ""')"
  pr="$(printf '%s' "$meta" | jq -r '.pr // ""')"

  if [[ "$created" < "$MERGE_TS" ]]; then cohort="pre"; else cohort="post"; fi
  path="$(derive_path "$labels")"
  bucket="$(file_count_bucket "$files_changed")"
  cache_creation="$(per_issue_metric "$num" cache_creation)"
  tokens_total="$(per_issue_metric "$num" total)"

  # accuracy + hint need the full view (comments)
  view="$(load_issue_view "$num" 2>/dev/null || echo '{}')"
  acc="$(mine_accuracy "$view")"
  read -r fp replan esc fix <<<"$acc"
  fp="${fp:-0}"; replan="${replan:-0}"; esc="${esc:-0}"; fix="${fix:-0}"
  hint="$(parse_hint "$body")"
  cpath="$(parse_classify_path "$view")"

  row="$(jq -nc \
    --argjson issue "$num" \
    --arg cohort "$cohort" \
    --arg path "$path" \
    --arg bucket "$bucket" \
    --argjson files_changed "${files_changed:-0}" \
    --argjson cache_creation "${cache_creation:-0}" \
    --argjson tokens_total "${tokens_total:-0}" \
    --arg wave "$wave" \
    --arg pr "$pr" \
    --argjson first_pass "$fp" \
    --argjson replan "$replan" \
    --argjson escalation "$esc" \
    --argjson fix "$fix" \
    --arg hint "$hint" \
    --arg classify_path "$cpath" \
    '{issue:$issue, cohort:$cohort, path:$path, file_count_bucket:$bucket,
      files_changed:$files_changed, cache_creation:$cache_creation,
      tokens_total:$tokens_total, wave:$wave, pr:$pr,
      first_pass:$first_pass, replan:$replan, escalation:$escalation,
      fix_commit:$fix, hint:$hint, classify_path:$classify_path}')"
  ROWS_JSON="$(printf '%s' "$ROWS_JSON" | jq -c --argjson r "$row" '. + [$r]')"
done

if [ "$EMIT_ROWS_JSON" -eq 1 ]; then
  printf '%s\n' "$ROWS_JSON" | jq '.'
  exit 0
fi

# --- aggregate metrics -----------------------------------------------------

# Buckets: per PATH × file_count_bucket, pre/post means of cache_creation.
BUCKETS_JSON="$(printf '%s' "$ROWS_JSON" | jq -c --argjson minn "$MIN_N" '
  group_by([.path, .file_count_bucket])
  | map({
      path: .[0].path,
      bucket: .[0].file_count_bucket,
      pre_n:  ([ .[] | select(.cohort=="pre") ] | length),
      post_n: ([ .[] | select(.cohort=="post") ] | length),
      pre_mean_cache_creation:  ( ([ .[] | select(.cohort=="pre")  | .cache_creation ]) as $p | if ($p|length)>0 then (($p|add)/($p|length)) else 0 end ),
      post_mean_cache_creation: ( ([ .[] | select(.cohort=="post") | .cache_creation ]) as $p | if ($p|length)>0 then (($p|add)/($p|length)) else 0 end )
    })
  | map(. + {
      cost_direction: (
        if .post_n == 0 or .pre_mean_cache_creation == 0 then "flat"
        elif .post_mean_cache_creation < (.pre_mean_cache_creation * 0.98) then "down"
        elif .post_mean_cache_creation > (.pre_mean_cache_creation * 1.02) then "up"
        else "flat" end ),
      insufficient: (.post_n < $minn)
    })
')"

# Structural per cohort.
structural_for() {
  local cohort="$1"
  printf '%s' "$ROWS_JSON" | jq -c --arg c "$cohort" '
    [ .[] | select(.cohort == $c) ] as $rows
    | {
        issues_created: ($rows | length),
        mean_files_per_issue: ( if ($rows|length)>0 then (([ $rows[].files_changed ]|add) / ($rows|length)) else 0 end ),
        pr_count: ([ $rows[] | select(.pr != "" and .pr != null) ] | length),
        wave_serialization: ([ $rows[].wave ] | unique | length)
      }'
}
STRUCT_PRE="$(structural_for pre)"
STRUCT_POST="$(structural_for post)"

# Accuracy per cohort.
accuracy_for() {
  local cohort="$1"
  printf '%s' "$ROWS_JSON" | jq -c --arg c "$cohort" '
    [ .[] | select(.cohort == $c) ] as $rows
    | {
        first_pass_approval_rate: ( if ($rows|length)>0 then (([ $rows[].first_pass ]|add) / ($rows|length)) else 0 end ),
        replan_count:    ([ $rows[].replan ] | add // 0),
        escalation_count:([ $rows[].escalation ] | add // 0),
        fix_commit_count:([ $rows[].fix_commit ] | add // 0)
      }'
}
ACC_PRE="$(accuracy_for pre)"
ACC_POST="$(accuracy_for post)"

# accuracy_worse: post first-pass approval < pre, OR post escalation/replan rate > pre.
ACCURACY_WORSE="$(jq -n --argjson pre "$ACC_PRE" --argjson post "$ACC_POST" \
  '($post.first_pass_approval_rate < $pre.first_pass_approval_rate)
   or (($post.escalation_count + $post.replan_count) > ($pre.escalation_count + $pre.replan_count))')"

# Hint quality (post-only).
HINT_QUALITY="$(printf '%s' "$ROWS_JSON" | jq -c '
  [ .[] | select(.cohort == "post") ] as $post
  | ([ $post[] | select(.hint != "" and .hint != null) ]) as $emitted
  | {
      cohort: "post",
      hint_emit_rate: ( if ($post|length)>0 then (($emitted|length) / ($post|length)) else null end ),
      hint_classify_agreement_rate: (
        if ($emitted|length)>0
        then (([ $emitted[] | select(.classify_path != "" and .hint == .classify_path) ] | length) / ($emitted|length))
        else null end )
    }')"

# Aggregate post N for the verdict gate.
POST_TOTAL_N="$(printf '%s' "$ROWS_JSON" | jq '[.[]|select(.cohort=="post")]|length')"
# Sufficient when at least one bucket clears MIN_N (post_n >= MIN_N).
SUFFICIENT="$(printf '%s' "$BUCKETS_JSON" | jq --argjson minn "$MIN_N" 'any(.[]; .post_n >= $minn)')"

# Verdict decision.
if [ "$SUFFICIENT" = "true" ]; then
  ANY_UP="$(printf '%s' "$BUCKETS_JSON" | jq --argjson minn "$MIN_N" 'any(.[]; .post_n >= $minn and .cost_direction == "up")')"
  if [ "$ANY_UP" = "true" ] || [ "$ACCURACY_WORSE" = "true" ]; then
    RECOMMENDATION="Revert-candidate"
  else
    RECOMMENDATION="Keep"
  fi
else
  RECOMMENDATION="INSUFFICIENT DATA"
fi

VERDICT_JSON="$(jq -n \
  --argjson buckets "$BUCKETS_JSON" \
  --argjson struct_pre "$STRUCT_PRE" \
  --argjson struct_post "$STRUCT_POST" \
  --argjson acc_pre "$ACC_PRE" \
  --argjson acc_post "$ACC_POST" \
  --argjson accuracy_worse "$ACCURACY_WORSE" \
  --argjson hint_quality "$HINT_QUALITY" \
  --argjson post_total_n "$POST_TOTAL_N" \
  --argjson min_n "$MIN_N" \
  --arg recommendation "$RECOMMENDATION" \
  --arg merge_ts "$MERGE_TS" \
  '{
     merge_ts: $merge_ts,
     buckets: $buckets,
     structural: {pre: $struct_pre, post: $struct_post},
     accuracy: {pre: $acc_pre, post: $acc_post},
     accuracy_worse: $accuracy_worse,
     hint_quality: $hint_quality,
     post_total_n: $post_total_n,
     min_n: $min_n,
     recommendation: $recommendation
   }')"

if [ "$EMIT_VERDICT_JSON" -eq 1 ]; then
  printf '%s\n' "$VERDICT_JSON" | jq '.'
  exit 0
fi

# --- rendered text report --------------------------------------------------
echo "combine + path-hint impact report (#757) — DOGFOOD-ONLY"
echo "cohort split (merge ts): $MERGE_TS   min-N: $MIN_N"
echo ""
echo "Cohort summary:"
printf '  pre : %s issues\n' "$(printf '%s' "$STRUCT_PRE" | jq -r '.issues_created')"
printf '  post: %s issues\n' "$(printf '%s' "$STRUCT_POST" | jq -r '.issues_created')"
echo ""
echo "Per-bucket cost (PATH × file-count):"
echo "  PATH | bucket | pre_n | post_n | pre_mean_cc | post_mean_cc | dir   | insufficient"
printf '%s' "$BUCKETS_JSON" | jq -r '.[] |
  "  \(.path)    | \(.bucket)    | \(.pre_n)     | \(.post_n)      | \(.pre_mean_cache_creation) | \(.post_mean_cache_creation) | \(.cost_direction) | \(.insufficient)"'
echo ""
echo "Structural:"
echo "  metric                | pre | post"
printf '  issues_created        | %s | %s\n' "$(printf '%s' "$STRUCT_PRE" | jq -r '.issues_created')" "$(printf '%s' "$STRUCT_POST" | jq -r '.issues_created')"
printf '  mean_files_per_issue  | %s | %s\n' "$(printf '%s' "$STRUCT_PRE" | jq -r '.mean_files_per_issue')" "$(printf '%s' "$STRUCT_POST" | jq -r '.mean_files_per_issue')"
printf '  pr_count              | %s | %s\n' "$(printf '%s' "$STRUCT_PRE" | jq -r '.pr_count')" "$(printf '%s' "$STRUCT_POST" | jq -r '.pr_count')"
printf '  wave_serialization    | %s | %s\n' "$(printf '%s' "$STRUCT_PRE" | jq -r '.wave_serialization')" "$(printf '%s' "$STRUCT_POST" | jq -r '.wave_serialization')"
echo ""
echo "Accuracy:"
echo "  metric                  | pre | post"
printf '  first_pass_approval     | %s | %s\n' "$(printf '%s' "$ACC_PRE" | jq -r '.first_pass_approval_rate')" "$(printf '%s' "$ACC_POST" | jq -r '.first_pass_approval_rate')"
printf '  replan_count            | %s | %s\n' "$(printf '%s' "$ACC_PRE" | jq -r '.replan_count')" "$(printf '%s' "$ACC_POST" | jq -r '.replan_count')"
printf '  escalation_count        | %s | %s\n' "$(printf '%s' "$ACC_PRE" | jq -r '.escalation_count')" "$(printf '%s' "$ACC_POST" | jq -r '.escalation_count')"
printf '  fix_commit_count        | %s | %s\n' "$(printf '%s' "$ACC_PRE" | jq -r '.fix_commit_count')" "$(printf '%s' "$ACC_POST" | jq -r '.fix_commit_count')"
printf '  accuracy_worse          | %s\n' "$ACCURACY_WORSE"
echo ""
echo "Hint quality (POST-ONLY):"
printf '  hint_emit_rate              | %s\n' "$(printf '%s' "$HINT_QUALITY" | jq -r '.hint_emit_rate')"
printf '  hint_classify_agreement     | %s\n' "$(printf '%s' "$HINT_QUALITY" | jq -r '.hint_classify_agreement_rate')"
echo ""

if [ "$RECOMMENDATION" = "INSUFFICIENT DATA" ]; then
  echo "VERDICT: INSUFFICIENT DATA — N=${POST_TOTAL_N} (need >= ${MIN_N})"
else
  echo "VERDICT: ${RECOMMENDATION} — recommendation only (operator decides)"
fi
