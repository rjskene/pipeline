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
