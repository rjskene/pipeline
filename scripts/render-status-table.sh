#!/bin/bash
# render-status-table.sh — deterministic, hermetic pipeline status table
# renderer.
#
# Usage:
#   render-status-table.sh --issues <issues.json> \
#                          [--trackers <trackers.json>] \
#                          [--release-prs <release-prs.txt>] \
#                          [--today YYYY-MM-DD]
#
# Inputs are FILES (no live `gh` calls). All three input shapes are produced
# upstream by `/pipeline:run` step 0–1:
#   issues.json     — verbatim `gh issue list --json number,title,labels,body,updatedAt`
#   trackers.json   — JSON object {"<num>": "<body string>", ...} per tracker
#   release-prs.txt — one line per release PR in the format
#                       pr=<num> ci=<pass|fail|pending> title=<title>
#                     (already emitted by scripts/list-release-prs.sh).
#
# Writes the canonical status table to stdout. Exit codes:
#   0 — success (incl. empty input that yields a minimally-headered table)
#   2 — missing/unparseable input or usage error
#
# Sources pipeline.config when present so label-name knobs
# (PIPELINE_BASE_BRANCH, PIPELINE_LABELS_*) resolve correctly.

set -uo pipefail

# ----- argv parsing ---------------------------------------------------

usage() {
  cat >&2 <<USAGE
usage: render-status-table.sh --issues <issues.json>
                              [--trackers <trackers.json>]
                              [--release-prs <release-prs.txt>]
                              [--today YYYY-MM-DD]
USAGE
}

ISSUES_FILE=""
TRACKERS_FILE=""
RELEASE_PRS_FILE=""
TODAY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --issues)      ISSUES_FILE="${2:-}"; shift 2 ;;
    --trackers)    TRACKERS_FILE="${2:-}"; shift 2 ;;
    --release-prs) RELEASE_PRS_FILE="${2:-}"; shift 2 ;;
    --today)       TODAY="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "render-status-table.sh: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$ISSUES_FILE" ]; then
  echo "render-status-table.sh: --issues is required" >&2
  usage
  exit 2
fi

if [ ! -f "$ISSUES_FILE" ]; then
  echo "render-status-table.sh: --issues file not found: $ISSUES_FILE" >&2
  exit 2
fi

if [ -n "$TRACKERS_FILE" ] && [ ! -f "$TRACKERS_FILE" ]; then
  echo "render-status-table.sh: --trackers file not found: $TRACKERS_FILE" >&2
  exit 2
fi

if [ -n "$RELEASE_PRS_FILE" ] && [ ! -f "$RELEASE_PRS_FILE" ]; then
  echo "render-status-table.sh: --release-prs file not found: $RELEASE_PRS_FILE" >&2
  exit 2
fi

[ -n "$TODAY" ] || TODAY=$(date -u +%Y-%m-%d)

# ----- pipeline.config sourcing --------------------------------------

# Resolve consumer project root the same way list-release-prs.sh does: prefer
# explicit env, fall back to cwd. We don't fail if pipeline.config is absent —
# the renderer falls back to defaults baked into pipeline.config.example.
_PROJECT_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
if [ -f "$_PROJECT_ROOT/pipeline.config" ]; then
  # shellcheck disable=SC1091
  source "$_PROJECT_ROOT/pipeline.config"
fi

: "${PIPELINE_BASE_BRANCH:=staging}"
: "${PIPELINE_LABELS_EXCLUDED:=excluded}"
: "${PIPELINE_LABELS_LATER:=later}"
: "${PIPELINE_LABELS_HUMAN:=human}"
: "${PIPELINE_LABELS_BRAINSTORM:=brainstorm}"

# ----- skeleton render (Task 1) --------------------------------------
#
# Subsequent tasks layer ORPHANS / EPICS / NOTES / counts / RELEASE PRs.
echo "PIPELINE STATUS — $TODAY"
echo "================================================================"
