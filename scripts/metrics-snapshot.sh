#!/bin/bash
set -uo pipefail
#
# metrics-snapshot.sh — DOGFOOD-ONLY daily metrics snapshot (issue #576).
#
# Aggregates four self-improvement signals into one JSONL row per run and
# appends it to .claude/logs/metrics-timeseries.jsonl. Append-only; the
# row schema is sticky once written.
#
# This script is for this repo's own dogfood operation only. It is NOT
# shipped in the plugin manifest and writes nothing under
# ${CLAUDE_PLUGIN_ROOT}. The only consumer-owned path it touches is
# .claude/logs/, which is already on the runtime allow-list per
# CLAUDE.md "Namespace discipline".
#
# Row schema (locked, see issue #576 plan task 2-A..2-D):
#   {
#     "date":                       "YYYY-MM-DD",        # UTC
#     "pipeline_version":           "<PIPELINE_VERSION or 'unknown'>",
#     "over_eval_count":            <int|null>,          # count of PRs with pr_eval/loc > 0.5
#     "late_error_count_by_stage":  {issue, plan, plan-eval, pr-eval : int},
#     "compliance_pass_rate":       <float|null>,        # PASS / (PASS + SKIP)
#     "review_deviations_count":    <int|null>           # wc -l of --deviations rows
#   }
#
# A sibling failure degrades that field to null — partial-day signal
# beats no-day signal. The script's exit code is 0 when any sibling
# degrades.
#
# Usage:
#   bash scripts/metrics-snapshot.sh
#   bash scripts/metrics-snapshot.sh --fixture <dir>   # test mode (4 named subdirs)
#   bash scripts/metrics-snapshot.sh --out <path>      # default .claude/logs/metrics-timeseries.jsonl
#   bash scripts/metrics-snapshot.sh --dry-run         # print row to stdout, do not append
#   bash scripts/metrics-snapshot.sh --help
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

print_usage() {
  cat <<'USAGE'
Usage: metrics-snapshot.sh [--fixture DIR] [--out PATH] [--dry-run] [--help]

  metrics-snapshot.sh — DOGFOOD-ONLY daily metrics snapshot.

  Aggregates over-eval-report, late-error-report, compliance-backfill, and
  review-audits into one JSONL row per run, appended to
  .claude/logs/metrics-timeseries.jsonl. Sibling failure degrades that
  field to null; the snapshot itself still exits 0.

  --fixture DIR    Pass <DIR>/over-eval, <DIR>/late-error, <DIR>/compliance
                   to each sibling's --fixture flag; read
                   <DIR>/review-audits/output.txt directly (review-audits.sh
                   has no --fixture flag). Test-mode only.
  --out PATH       Output JSONL file (default .claude/logs/metrics-timeseries.jsonl).
  --dry-run        Assemble + print the row to stdout, do NOT append.
  --help           Print this banner and exit 0.
USAGE
}

FIXTURE_DIR=""
OUT_PATH=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)    print_usage; exit 0 ;;
    --fixture)    FIXTURE_DIR="${2:-}"; shift 2 ;;
    --fixture=*)  FIXTURE_DIR="${1#--fixture=}"; shift ;;
    --out)        OUT_PATH="${2:-}"; shift 2 ;;
    --out=*)      OUT_PATH="${1#--out=}"; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    *)
      echo "metrics-snapshot: ERROR: unknown arg: $1" >&2
      exit 1 ;;
  esac
done

if [ -z "$OUT_PATH" ]; then
  OUT_PATH="${REPO_ROOT}/.claude/logs/metrics-timeseries.jsonl"
fi

# Source pipeline.config for PIPELINE_VERSION if set; tolerate absence.
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/pipeline.config" ] && source "${REPO_ROOT}/pipeline.config" 2>/dev/null || true
VERSION="${PIPELINE_VERSION:-unknown}"
DATE_UTC="$(date -u +%Y-%m-%d)"

OVER_EVAL_BIN="${REPO_ROOT}/scripts/over-eval-report.sh"
LATE_ERROR_BIN="${REPO_ROOT}/scripts/late-error-report.sh"
COMPLIANCE_BIN="${REPO_ROOT}/scripts/compliance-backfill.sh"
REVIEW_AUDITS_BIN="${REPO_ROOT}/scripts/review-audits.sh"

# Resolve per-sibling fixture flags as arrays so paths containing spaces
# (test tmpdirs, $HOME on some hosts) are preserved as a single arg. In
# live mode the arrays stay empty so each sibling hits `gh`.
OE_FIX=()
LE_FIX=()
CB_FIX=()
if [ -n "$FIXTURE_DIR" ]; then
  OE_FIX=(--fixture "${FIXTURE_DIR}/over-eval")
  LE_FIX=(--fixture "${FIXTURE_DIR}/late-error")
  CB_FIX=(--fixture "${FIXTURE_DIR}/compliance")
fi

# --- (2-A) over_eval_count ---
# count of PRs in the window with pr_eval / max(loc,1) > 0.5
if out=$(bash "$OVER_EVAL_BIN" "${OE_FIX[@]}" --emit-rows-json 2>/dev/null) && [ -n "$out" ]; then
  if scalar=$(printf '%s' "$out" | jq -e '
        map(select(
          (.pr_eval | tonumber) /
          ((.loc | tonumber) | if . == 0 then 1 else . end) > 0.5
        )) | length
      ' 2>/dev/null); then
    OVER_EVAL_JSON="$scalar"
  else
    OVER_EVAL_JSON="null"
  fi
else
  OVER_EVAL_JSON="null"
fi

# --- (2-B) late_error_count_by_stage ---
# all four canonical stages present (zeros included); non-canonical stages pass through.
if out=$(bash "$LATE_ERROR_BIN" "${LE_FIX[@]}" --emit-rows-json 2>/dev/null) && [ -n "$out" ]; then
  if scalar=$(printf '%s' "$out" | jq -ec '
        {issue: 0, plan: 0, "plan-eval": 0, "pr-eval": 0}
        + (group_by(.stage) | map({(.[0].stage): length}) | add // {})
      ' 2>/dev/null); then
    LATE_ERROR_JSON="$scalar"
  else
    LATE_ERROR_JSON="null"
  fi
else
  LATE_ERROR_JSON="null"
fi

# --- (2-C) compliance_pass_rate ---
# PASS / (PASS + SKIP); N/A and omitted excluded; null when denom == 0.
if out=$(bash "$COMPLIANCE_BIN" "${CB_FIX[@]}" --emit-rows-json 2>/dev/null) && [ -n "$out" ]; then
  if scalar=$(printf '%s' "$out" | jq -e '
        (map(select(.verdict == "PASS")) | length) as $pass
        | (map(select(.verdict == "PASS" or .verdict == "SKIP")) | length) as $denom
        | if $denom == 0 then null else ($pass / $denom) end
      ' 2>/dev/null); then
    COMPLIANCE_JSON="$scalar"
  else
    COMPLIANCE_JSON="null"
  fi
else
  COMPLIANCE_JSON="null"
fi

# --- (2-D) review_deviations_count ---
# wc -l of yesterday's deviation rows.
# Fixture path: review-audits.sh itself has no --fixture flag, so in test
# mode we substitute a pre-baked output file (one deviation per line).
if [ -n "$FIXTURE_DIR" ]; then
  rv_output_file="${FIXTURE_DIR}/review-audits/output.txt"
  if [ -f "$rv_output_file" ]; then
    REVIEW_JSON=$(wc -l < "$rv_output_file" | tr -d ' ')
  else
    REVIEW_JSON="null"
  fi
else
  SINCE_DATE=$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null)
  if [ -z "$SINCE_DATE" ]; then
    REVIEW_JSON="null"
  elif out=$(bash "$REVIEW_AUDITS_BIN" --deviations --since "$SINCE_DATE" 2>/dev/null); then
    REVIEW_JSON=$(printf '%s' "$out" | grep -c . | tr -d ' ')
  else
    REVIEW_JSON="null"
  fi
fi

# --- Assemble row ---
ROW=$(jq -nc \
  --arg date "$DATE_UTC" \
  --arg version "$VERSION" \
  --argjson over_eval "$OVER_EVAL_JSON" \
  --argjson late_error "$LATE_ERROR_JSON" \
  --argjson compliance "$COMPLIANCE_JSON" \
  --argjson review "$REVIEW_JSON" \
  '{
    date: $date,
    pipeline_version: $version,
    over_eval_count: $over_eval,
    late_error_count_by_stage: $late_error,
    compliance_pass_rate: $compliance,
    review_deviations_count: $review
  }')

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$ROW"
  exit 0
fi

mkdir -p "$(dirname "$OUT_PATH")"
printf '%s\n' "$ROW" >> "$OUT_PATH"
exit 0
