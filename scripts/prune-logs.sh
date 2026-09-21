#!/bin/bash
set -uo pipefail

# prune-logs.sh — retention pass over .claude/logs/ (issue #1353).
#
# Dry run by default. Prints one "PRUNE path=<rel> age_days=<n>" line per
# candidate file, then exactly one "SUMMARY ..." line, and exits 0 on every
# non-usage path.
#
# Usage: bash scripts/prune-logs.sh [--apply] [--days N]
#
# Retention window resolution (first wins):
#   --days N  >  PIPELINE_LOGS_RETENTION_DAYS  >  30 (built-in default)
#
# Log dir resolution (first wins):
#   PIPELINE_PROJECT_ROOT  >  CLAUDE_PROJECT_DIR  >  main-worktree root
#   (git rev-parse --git-common-dir, its parent — so a call from inside a
#   linked worktree prunes the MAIN tree's logs, not the worktree copy)  >
#   pwd (fail-open, e.g. hermetic non-git test fixtures).
#   Logs dir is <root>/.claude/logs.
#
# KEEP-LIST is checked BEFORE any prune glob. A NEW aggregate/live-stream
# file is safe only if it is added here, or if it fails to match a prune
# glob at all:
#   agent-costs.jsonl, tokenomics-history.jsonl, usage-gate.jsonl,
#   metrics-timeseries.jsonl, metrics-snapshot.cron.log,
#   agent-cost-orchestrator-state.json, tool-use.log, subagents.log,
#   runs.log, hook-errors.log, dogfood-refresh.log, plan-drafts/*
#
# PRUNE SET (evaluated only after the keep-list check): top-level
# issue-<N>-<stamp>.log, issue-<N>-plan.md, issue-<N>-eval.log,
# issue-<N>-execute.log, queue-*.log, tool-use-issue-<N>.log,
# ci-fix-<N>-attempt-<k>.log, fullsend-*.out, runner-*.log,
# analyze-shortlist-*.json; plus everything under subagents/ at any depth.
# Anything matching neither list is left alone (default-safe).
#
# Age: age_days = floor((now - mtime) / 86400) via `stat -c %Y`; candidate
# iff age_days > RETENTION (strict — a file exactly at the window survives).
#
# --apply deletes candidates; it is gated behind the repo's existing
# ALLOW_DELETIONS convention (env ALLOW_DELETIONS=true, else
# .env.ALLOW_DELETIONS from <root>/.claude/settings.local.json via jq).
# With --apply and the gate not "true": the PRUNE lines and a mode=dry-run
# SUMMARY are still printed, a notice naming ALLOW_DELETIONS goes to
# stderr, and nothing is deleted. Deletes files only — empty directories
# (including subagents/) are left in place; no rmdir sweep.

usage() {
  cat <<'EOF'
Usage: bash scripts/prune-logs.sh [--apply] [--days N]

Retention pass over .claude/logs/. Dry run by default; prints one
"PRUNE path=<rel> age_days=<n>" line per candidate file (aged past the
retention window), followed by exactly one "SUMMARY ..." line.

  --apply       Delete candidates instead of just listing them. Requires
                the ALLOW_DELETIONS gate (env ALLOW_DELETIONS=true, or
                .env.ALLOW_DELETIONS=true in
                <root>/.claude/settings.local.json) to actually delete;
                otherwise behaves like a dry run and prints a notice to
                stderr.
  --days N      Override the retention window (in days). Beats
                PIPELINE_LOGS_RETENTION_DAYS and the built-in default of 30.
  -h, --help    Show this help and exit 0.
EOF
}

APPLY=0
DAYS_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --days)
      shift
      if [ "$#" -eq 0 ]; then
        echo "prune-logs: --days requires an argument" >&2
        usage >&2
        exit 2
      fi
      DAYS_OVERRIDE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "prune-logs: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "$DAYS_OVERRIDE" ]; then
  case "$DAYS_OVERRIDE" in
    ''|*[!0-9]*)
      echo "prune-logs: --days must be a non-negative integer, got: $DAYS_OVERRIDE" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

RETENTION="${DAYS_OVERRIDE:-${PIPELINE_LOGS_RETENTION_DAYS:-30}}"

# --- Resolve project root -> logs dir --------------------------------------
resolve_root() {
  if [ -n "${PIPELINE_PROJECT_ROOT:-}" ]; then
    printf '%s\n' "$PIPELINE_PROJECT_ROOT"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  local common_dir
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common_dir" ]; then
    case "$common_dir" in
      /*) : ;;
      *)  common_dir="$PWD/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" && pwd)
    return 0
  fi
  pwd
}

ROOT="$(resolve_root)"
LOGS_DIR="$ROOT/.claude/logs"

# --- Keep-list / prune-set classification ----------------------------------
is_keep() {
  case "$1" in
    agent-costs.jsonl|tokenomics-history.jsonl|usage-gate.jsonl|\
    metrics-timeseries.jsonl|metrics-snapshot.cron.log|\
    agent-cost-orchestrator-state.json|tool-use.log|subagents.log|\
    runs.log|hook-errors.log|dogfood-refresh.log)
      return 0
      ;;
    plan-drafts/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_prune_candidate() {
  case "$1" in
    */*)
      case "$1" in
        subagents/*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    issue-*.log|issue-*.md|queue-*.log|tool-use-issue-*.log|\
    ci-fix-*.log|fullsend-*.out|runner-*.log|analyze-shortlist-*.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

CAND_PATHS=()
CAND_AGES=()
CAND_BYTES=()

if [ -d "$LOGS_DIR" ]; then
  NOW="$(date +%s)"
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    is_keep "$rel" && continue
    is_prune_candidate "$rel" || continue
    f="$LOGS_DIR/$rel"
    mtime="$(stat -c %Y "$f" 2>/dev/null || echo "$NOW")"
    age_days=$(( (NOW - mtime) / 86400 ))
    [ "$age_days" -gt "$RETENTION" ] || continue
    size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    CAND_PATHS+=("$rel")
    CAND_AGES+=("$age_days")
    CAND_BYTES+=("$size")
  done < <(cd "$LOGS_DIR" && find . -type f 2>/dev/null | sed 's#^\./##' | sort)
fi

N="${#CAND_PATHS[@]}"
TOTAL_BYTES=0
for b in "${CAND_BYTES[@]:-}"; do
  [ -n "$b" ] && TOTAL_BYTES=$((TOTAL_BYTES + b))
done

print_prune_lines() {
  local i
  for ((i = 0; i < N; i++)); do
    echo "PRUNE path=${CAND_PATHS[$i]} age_days=${CAND_AGES[$i]}"
  done
}

allow_deletions() {
  if [ -n "${ALLOW_DELETIONS:-}" ]; then
    printf '%s\n' "$ALLOW_DELETIONS"
    return 0
  fi
  jq -r '.env.ALLOW_DELETIONS // empty' "$ROOT/.claude/settings.local.json" 2>/dev/null || true
}

if [ "$APPLY" -eq 1 ]; then
  GATE="$(allow_deletions)"
  if [ "$GATE" = "true" ]; then
    print_prune_lines
    for p in "${CAND_PATHS[@]:-}"; do
      [ -n "$p" ] && rm -f "$LOGS_DIR/$p"
    done
    echo "SUMMARY deleted=$N bytes=$TOTAL_BYTES mode=apply"
  else
    print_prune_lines
    echo "SUMMARY candidates=$N bytes=$TOTAL_BYTES mode=dry-run"
    echo "prune-logs: ALLOW_DELETIONS != true — no files deleted (set ALLOW_DELETIONS=true to enable)" >&2
  fi
else
  print_prune_lines
  echo "SUMMARY candidates=$N bytes=$TOTAL_BYTES mode=dry-run"
fi

exit 0
