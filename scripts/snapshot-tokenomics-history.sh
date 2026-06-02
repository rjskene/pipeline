#!/usr/bin/env bash
# snapshot-tokenomics-history.sh — DOGFOOD-ONLY per-day history snapshot (#832).
#
# Persists a durable per-day aggregate of the tokenomics cost/token figures so
# the seed-doc shape survives raw-log pruning. Invokes
#   cost-latency-report.sh --emit-day-json
# (which reuses the report's already-built dedup / reconcile / pricing / LOC-
# join substrate — ONE aggregation path, avoiding the #643/#642 schema-drift
# class) and UPSERTS each emitted day object into
#   .claude/logs/tokenomics-history.jsonl
# keyed by `date` (last-write-wins). Re-running a day overwrites its row, so as
# lower-bounds reconcile UPWARD (usage_complete flips, totals grow) the stored
# row grows monotonically; `usage_complete_floor` records whether the row is
# still a floor. This is the durability complement to #830 (which stops new
# lower-bounds stranding capture-side).
#
# Gated behind PIPELINE_LOGS_ENABLED — a gated-off run emits the
# SKIP_LOGGING_DISABLED marker + exits 0, byte-for-byte mirroring
# capture-agent-costs.sh so the tokenomics skill's skip-detection works
# unchanged. No new runtime capture surface; compute-retroactive only.
#
# Store resolves to the MAIN worktree (git --git-common-dir), exactly like
# capture-agent-costs.sh's output log, so a snapshot run from a linked worktree
# still lands in the durable main-worktree store. .claude/logs/ is already on
# the runtime allow-list (CLAUDE.md "Namespace discipline") — no allow-list
# entry needed.
#
# Cadence is operator-applied: the cron entry runs on the operator's host more
# frequently than transcript/log retention (same pattern as the
# capture-agent-costs.sh cron). The live pipeline.config/crontab is host-
# specific and hand-patched (CLAUDE.md "Configuration conventions"); this script
# ships the logic, the operator wires the crontab line locally.
#
# Usage:
#   PIPELINE_LOGS_ENABLED=true CLAUDE_PROJECT_DIR=$(pwd) \
#     bash scripts/snapshot-tokenomics-history.sh [--since D] [--until D] \
#       [--limit N] [--capture-log PATH] [--fixture DIR]
# Passthrough flags are forwarded verbatim to cost-latency-report.sh.
set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$THIS_DIR/_logging.sh"

REPORT="$THIS_DIR/cost-latency-report.sh"

if ! pipeline_logging_enabled; then
  # Verbatim mirror of capture-agent-costs.sh lines 63-71: stderr is the human
  # message; the stdout marker is what the tokenomics skill greps for to tell an
  # intentional opt-out from a propagation failure.
  echo "snapshot-tokenomics-history: PIPELINE_LOGS_ENABLED not 'true'; skipping (no writes)." >&2
  echo "snapshot-tokenomics-history: SKIP_LOGGING_DISABLED (PIPELINE_LOGS_ENABLED='${PIPELINE_LOGS_ENABLED:-<unset>}')"
  exit 0
fi

# Resolve the persisted store to the MAIN worktree. Mirrors capture-agent-
# costs.sh lines ~82-95 (and resolve_history_store() in cost-latency-report.sh
# — keep the three in sync). Fail-open to PROJECT_DIR for non-git/hermetic dirs.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$THIS_DIR/.." && pwd)}"
common_dir="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$common_dir" ]; then
  case "$common_dir" in
    /*) main_root="$(cd "$(dirname "$common_dir")" && pwd)" ;;
    *)  main_root="$(cd "$PROJECT_DIR/$(dirname "$common_dir")" && pwd)" ;;
  esac
else
  main_root="$PROJECT_DIR"
fi
out_logs_dir="$main_root/.claude/logs"
store="$out_logs_dir/tokenomics-history.jsonl"
mkdir -p "$out_logs_dir"

# All remaining args are forwarded verbatim to the report's --emit-day-json
# mode (--since/--until/--limit/--capture-log/--fixture). When no window is
# given the report applies its own default (the --since/--until defaults).
DAYS="$(bash "$REPORT" "$@" --emit-day-json)"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "snapshot-tokenomics-history: cost-latency-report --emit-day-json failed (rc=$RC); store unchanged." >&2
  exit "$RC"
fi

# Upsert: index existing store by .date, overlay incoming by .date (incoming
# wins → last-write-wins reconcile-upward), sort ascending by date. Write
# atomically to a tempfile then mv over the store. Records with NO .date are
# dropped (defensive). An empty incoming set leaves the store untouched.
tmp="$(mktemp "${store}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
existing="[]"
if [ -s "$store" ]; then
  existing="$(jq -s '.' "$store" 2>/dev/null || echo '[]')"
fi
printf '%s\n' "$DAYS" | jq -s \
  --argjson existing "$existing" '
    (($existing + .)
       | map(select(.date != null))
       | group_by(.date)
       | map(.[-1])
       | sort_by(.date))[]
  ' -c > "$tmp"
mv "$tmp" "$store"
trap - EXIT

WROTE="$(printf '%s\n' "$DAYS" | jq -s '[ .[] | select(.date != null) ] | length' 2>/dev/null || echo 0)"
echo "snapshot-tokenomics-history: wrote $WROTE day(s) to $store"
