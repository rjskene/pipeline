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
# absent). Live mode resolves $CAPTURE_LOG (default .claude/logs/agent-usage.jsonl,
# overridable by --capture-log) and cats it when present; emits empty otherwise
# so the report still works (all token/duration cells render `--`).
#
# This is the ONLY coupling point with #642's writer. The schema this reads:
#   {"issue":<int>,"stage":"classify|plan|plan-eval|execute|pr-eval",
#    "agent_type":"<str>","tokens":{"input":<int>,"output":<int>,"cache":<int>},
#    "duration_ms":<int>}
# A #642 rename is a one-line change to the CAPTURE_LOG default below.
load_capture() {
  if [ -n "$FIXTURE_DIR" ]; then
    if [ -f "$FIXTURE_DIR/capture.jsonl" ]; then
      cat "$FIXTURE_DIR/capture.jsonl"
    fi
  else
    local path="${CAPTURE_LOG:-${REPO_ROOT}/.claude/logs/agent-usage.jsonl}"
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

if [ "$EMIT_ROWS_JSON" -eq 1 ]; then
  echo "[]"
  exit 0
fi
