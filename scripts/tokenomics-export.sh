#!/bin/bash
# tokenomics-export.sh — gated, redacted telemetry export (#1617).
#
# Backs `/pipeline:tokenomics --export [--post] [--dry-run] [--since D] [--until D]`.
# Renders an aggregate cost summary of the consumer's own capture log
# (.claude/logs/agent-costs.jsonl) into
#   ${CLAUDE_PROJECT_DIR:-.}/.claude/scratch/telemetry/export-<ts>.{json,md}
# and, ONLY with the explicit --post, files it as a comment on the telemetry
# drop-box issue (${PIPELINE_TELEMETRY_REPO:-rjskene/pipeline}
# #${PIPELINE_TELEMETRY_ISSUE:-1615}) under the operator's own gh identity.
# --dry-run prints the body (export-<ts>.body.md) and the exact gh command
# without calling gh. A failed post prints POST-FAILED rc=<n> and still exits 0
# (the files stay for a re-run or a manual post).
#
# One aggregation substrate: per-record pricing, dedup, usage_complete scoping
# and the window all come from cost-latency-report.sh
# (--emit-priced-records-json + --emit-day-json), so this script keeps no
# second copy of the price table. The report projects each record to 7
# non-identifying keys, so agent/session ids, record keys, issue numbers and
# descriptions never reach this process. The repo name is exported only as a
# 12-hex sha256 prefix (repo_id).
#
# Gated behind PIPELINE_LOGS_ENABLED; a gated-off run prints the sibling
# SKIP_LOGGING_DISABLED marker and exits 0.
#
# Usage:
#   PIPELINE_REPO=o/r PIPELINE_LOGS_ENABLED=true CLAUDE_PROJECT_DIR=$(pwd) \
#     bash scripts/tokenomics-export.sh [--since D] [--until D] [--post] [--dry-run]
set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$THIS_DIR/_logging.sh"

if ! pipeline_logging_enabled; then
  echo "tokenomics-export: PIPELINE_LOGS_ENABLED not 'true'; skipping (no writes)." >&2
  echo "tokenomics-export: SKIP_LOGGING_DISABLED (PIPELINE_LOGS_ENABLED='${PIPELINE_LOGS_ENABLED:-<unset>}')"
  exit 0
fi

SINCE=""
UNTIL=""
POST=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since|--until)
      # A trailing flag with no value would make `shift 2` a no-op (infinite loop).
      if [ $# -lt 2 ]; then
        echo "tokenomics-export: ERROR: $1 needs a value (YYYY-MM-DD)" >&2
        exit 1
      fi
      if [ "$1" = "--since" ]; then SINCE="$2"; else UNTIL="$2"; fi
      shift 2 ;;
    --since=*)  SINCE="${1#--since=}"; shift ;;
    --until=*)  UNTIL="${1#--until=}"; shift ;;
    --post)     POST=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    *)
      echo "tokenomics-export: ERROR: unknown arg: $1" >&2
      exit 1 ;;
  esac
done
# Default window: 30 inclusive UTC days ending today, by ts_start.
[ -z "$UNTIL" ] && UNTIL="$(date -u +%F)"
[ -z "$SINCE" ] && SINCE="$(date -u -d "$UNTIL -29 days" +%F)"

if [ -z "${PIPELINE_REPO:-}" ]; then
  echo "tokenomics-export: ERROR: PIPELINE_REPO not set" >&2
  exit 1
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
LOG="$PROJECT_DIR/.claude/logs/agent-costs.jsonl"
REPORT="$THIS_DIR/cost-latency-report.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! bash "$REPORT" --capture-log "$LOG" --since "$SINCE" --until "$UNTIL" \
     --emit-priced-records-json > "$WORK/records.jsonl" 2>"$WORK/records.err"; then
  echo "tokenomics-export: WARN: --emit-priced-records-json failed; exporting records_n 0" >&2
  : > "$WORK/records.jsonl"
fi
if bash "$REPORT" --capture-log "$LOG" --since "$SINCE" --until "$UNTIL" \
     --emit-day-json > "$WORK/days.jsonl" 2>"$WORK/days.err"; then
  jq -s '.' "$WORK/days.jsonl" > "$WORK/days.json" 2>/dev/null || echo '[]' > "$WORK/days.json"
else
  echo "tokenomics-export: WARN: --emit-day-json failed; exporting days []" >&2
  echo '[]' > "$WORK/days.json"
fi

python3 - "$WORK/records.jsonl" > "$WORK/agg.json" <<'PY'
import json, statistics, sys
from collections import defaultdict

BUCKETS = ("input", "output", "cache_creation", "cache_read", "total")
recs = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict):
            recs.append(obj)

groups = defaultdict(list)
kinds = defaultdict(list)
for r in recs:
    groups[(r.get("stage") or "", r.get("model") or "")].append(r)
    kinds[r.get("agent_kind") or ""].append(r)

def cost(rs):
    return round(sum(r["cost_usd"] for r in rs if r.get("cost_usd") is not None), 4)

stages = []
for (stage, model), rs in groups.items():
    tok = {b: sum(((r.get("tokens") or {}).get(b) or 0) for r in rs) for b in BUCKETS}
    durs = [r["duration_ms"] for r in rs if isinstance(r.get("duration_ms"), (int, float))]
    stages.append({
        "stage": stage,
        "model": model,
        "n": len(rs),
        "tokens": tok,
        "cost_usd": cost(rs),
        "duration_ms_p50": int(statistics.median(durs)) if durs else None,
    })
stages.sort(key=lambda g: (-g["cost_usd"], g["stage"], g["model"]))
kind_rows = [{"agent_kind": k, "n": len(rs), "cost_usd": cost(rs)} for k, rs in sorted(kinds.items())]
json.dump({"records_n": len(recs), "stages": stages, "kinds": kind_rows}, sys.stdout)
PY

PLUGIN_JSON="${CLAUDE_PLUGIN_ROOT:-$THIS_DIR/..}/.claude-plugin/plugin.json"
PLUGIN_VERSION="$(jq -r '.version // "unknown"' "$PLUGIN_JSON" 2>/dev/null)"
[ -z "$PLUGIN_VERSION" ] && PLUGIN_VERSION="unknown"
REPO_ID="$(printf '%s' "$PIPELINE_REPO" | sha256sum | cut -c1-12)"
EXPORTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

OUT_DIR="$PROJECT_DIR/.claude/scratch/telemetry"
mkdir -p "$OUT_DIR"
OUT_JSON="$OUT_DIR/export-$TS.json"
OUT_MD="$OUT_DIR/export-$TS.md"

jq -n --arg pv "$PLUGIN_VERSION" --arg at "$EXPORTED_AT" --arg since "$SINCE" \
  --arg until "$UNTIL" --arg rid "$REPO_ID" \
  --slurpfile agg "$WORK/agg.json" --slurpfile days "$WORK/days.json" '
  { schema_version: 1,
    plugin_version: $pv,
    exported_at: $at,
    window: {since: $since, until: $until},
    repo_id: $rid,
    records_n: $agg[0].records_n,
    days: $days[0],
    stages: $agg[0].stages,
    kinds: $agg[0].kinds }' > "$OUT_JSON"

{
  jq -r '"plugin \(.plugin_version) · window \(.window.since)→\(.window.until) · repo_id \(.repo_id) · records \(.records_n)"' "$OUT_JSON"
  echo ""
  echo "| stage | model | n | tokens.total | cost_usd | duration_ms_p50 |"
  echo "|---|---|---|---|---|---|"
  jq -r '.stages[] | "| \(if .stage == "" then "--" else .stage end) | \(if .model == "" then "--" else .model end) | \(.n) | \(.tokens.total) | \(.cost_usd) | \(.duration_ms_p50 // "--") |"' "$OUT_JSON"
  echo ""
  echo "| date | n | tokens.total | cost.total |"
  echo "|---|---|---|---|"
  jq -r '.days[] | "| \(.date) | \(.n) | \(.tokens.total // 0) | \(.cost.total // 0) |"' "$OUT_JSON"
} > "$OUT_MD"

RECORDS_N="$(jq -r '.records_n' "$OUT_JSON")"
DAYS_N="$(jq -r '.days | length' "$OUT_JSON")"
echo "EXPORT json=$OUT_JSON md=$OUT_MD records=$RECORDS_N days=$DAYS_N"

# --- --post / --dry-run: the telemetry drop-box (consent = the explicit --post) ---
TELEMETRY_REPO="${PIPELINE_TELEMETRY_REPO:-rjskene/pipeline}"
TELEMETRY_ISSUE="${PIPELINE_TELEMETRY_ISSUE:-1615}"
OUT_BODY="$OUT_DIR/export-$TS.body.md"
{
  cat "$OUT_MD"
  echo ""
  echo '```json'
  jq '.' "$OUT_JSON"
  echo '```'
} > "$OUT_BODY"

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$OUT_BODY"
  echo "gh issue comment $TELEMETRY_ISSUE --repo $TELEMETRY_REPO --body-file $OUT_BODY"
  exit 0
fi

if [ "$POST" -eq 1 ]; then
  url="$(gh issue comment "$TELEMETRY_ISSUE" --repo "$TELEMETRY_REPO" --body-file "$OUT_BODY" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "POSTED url=$(printf '%s\n' "$url" | tail -1)"
  else
    echo "POST-FAILED rc=$rc"
  fi
fi
exit 0
