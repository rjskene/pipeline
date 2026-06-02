#!/bin/bash
set -uo pipefail
#
# usage-surface.sh — DOGFOOD-ONLY rolling-window usage read-out (issue #725).
#
# A pure READER over the gated #642/#721 agent-cost capture
# (.claude/logs/agent-costs.jsonl, the same PIPELINE_LOGS_ENABLED substrate as
# capture-agent-costs.sh / cost-latency-report.sh — already on the runtime
# allow-list per CLAUDE.md "Namespace discipline"). It computes, over a rolling
# time window:
#   - window-token-usage  (deduped sum of tokens.total inside the window)
#   - headroom            (cap - window-usage, floored at 0)
#   - throttle-ETA        (projected wall-clock to exhaust headroom at the
#                          observed burn rate)
# and renders a single advisory read-out line so the operator can size the next
# campaign leg with the headroom number in hand.
#
# READ-ONLY BY MANDATE. Zero writes, zero consumer footprint, no MAX_AGENTS
# extension, no hold/queue, no auto-pacing, no consumer path — all out of scope
# per #725 (consumer = phase 2 / #722; control loop dropped 2026-06-02).
#
# Both PIPELINE_USAGE_WINDOW_HOURS (default 5) and PIPELINE_USAGE_CAP_TOKENS
# (unset = read-out disabled) drive the read-out; gated alongside
# PIPELINE_LOGS_ENABLED (emits SKIP_LOGGING_DISABLED when logs off, mirroring
# capture-agent-costs.sh). The capture-log path and config are injectable via
# flags so #722's consumer path can re-point the same reader without a rewrite.
#

print_usage() {
  cat <<'USAGE'
Usage: usage-surface.sh [--capture-log PATH] [--window-hours N]
                        [--cap-tokens N] [--now ISO8601] [--help]

  usage-surface.sh — DOGFOOD-ONLY rolling-window usage read-out.

  Reads ONLY the gated agent-cost capture (.claude/logs/agent-costs.jsonl) and
  reports window-token-usage / headroom / throttle-ETA over a rolling window.
  READ-ONLY: no writes, no control loop. Degrades to `--` when the log is
  absent/empty or config is unset; never errors.

  --capture-log PATH  Override the capture JSONL path
                      (default: .claude/logs/agent-costs.jsonl).
  --window-hours N    Rolling-window length in hours
                      (default: $PIPELINE_USAGE_WINDOW_HOURS or 5).
  --cap-tokens N      Token ceiling to measure headroom against
                      (default: $PIPELINE_USAGE_CAP_TOKENS; unset = disabled).
  --now ISO8601       Injected clock for deterministic tests
                      (default: current UTC time).
  --help              Print this banner and exit 0.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)        print_usage; exit 0 ;;
    *)
      echo "usage-surface: ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done
