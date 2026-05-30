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
# default .claude/logs/agent-usage.jsonl) — already on the runtime
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
                       .claude/logs/agent-usage.jsonl). Ignored in fixture mode.
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
