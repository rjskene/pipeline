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

# Config from env (overridable by flags below).
WINDOW_HOURS="${PIPELINE_USAGE_WINDOW_HOURS:-5}"
CAP_TOKENS="${PIPELINE_USAGE_CAP_TOKENS:-}"
CAPTURE_LOG=""
NOW=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)         print_usage; exit 0 ;;
    --capture-log)     CAPTURE_LOG="${2:-}"; shift 2 ;;
    --capture-log=*)   CAPTURE_LOG="${1#--capture-log=}"; shift ;;
    --window-hours)    WINDOW_HOURS="${2:-}"; shift 2 ;;
    --window-hours=*)  WINDOW_HOURS="${1#--window-hours=}"; shift ;;
    --cap-tokens)      CAP_TOKENS="${2:-}"; shift 2 ;;
    --cap-tokens=*)    CAP_TOKENS="${1#--cap-tokens=}"; shift ;;
    --now)             NOW="${2:-}"; shift 2 ;;
    --now=*)           NOW="${1#--now=}"; shift ;;
    *)
      echo "usage-surface: ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# --- gating: PIPELINE_LOGS_ENABLED (mirror capture-agent-costs.sh) ---
# Loud, machine-detectable skip when logging is disabled.
if [ "${PIPELINE_LOGS_ENABLED:-false}" != "true" ]; then
  echo "usage-surface: PIPELINE_LOGS_ENABLED not 'true'; skipping (read-only, no output)." >&2
  echo "usage-surface: SKIP_LOGGING_DISABLED (PIPELINE_LOGS_ENABLED='${PIPELINE_LOGS_ENABLED:-<unset>}')"
  exit 0
fi

# --- gating: cap required to render ---
if [ -z "$CAP_TOKENS" ]; then
  echo "Usage read-out: disabled (PIPELINE_USAGE_CAP_TOKENS unset)"
  exit 0
fi

WINDOW_HOURS="${WINDOW_HOURS:-5}"

# Resolve the capture-log path (default the gated allow-listed log).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPTURE_LOG="${CAPTURE_LOG:-${REPO_ROOT}/.claude/logs/agent-costs.jsonl}"

# Resolve the clock: --now wins; else current UTC.
NOW="${NOW:-$(date -u +%FT%TZ)}"

# --- graceful-degrade: missing/empty capture log → -- placeholders ---
if [ ! -s "$CAPTURE_LOG" ]; then
  echo "Usage read-out (${WINDOW_HOURS}h window): window=--tok / cap=${CAP_TOKENS}tok — headroom=--tok — throttle-ETA --"
  exit 0
fi

# --- window-usage: deduped sum of tokens.total inside the rolling window ---
# Reproduce the cost-latency-report.sh two-pass dedup BEFORE summing (#698):
#   (1) group_by(.record_key) | last     — keyed records last-write-wins
#       (keyless records passed through, each its own group)
#   (2) group_by(session_id,issue,stage) | max_by(.tokens.total)
#       (records missing session_id passed through untouched)
# Then keep records whose ts_start is non-empty AND >= (now - window_hours),
# compared via fromdateiso8601. Emit "<sum> <earliest-in-window-epoch|->" so the
# caller can compute the elapsed span for the burn-rate projection.
WINDOW_DATA="$(jq -rs \
  --arg now "$NOW" --argjson wh "$WINDOW_HOURS" '
  ( ([ .[] | select(has("record_key") and .record_key != null) ]
       | group_by(.record_key) | map(.[-1]))
    + [ .[] | select((has("record_key") | not) or .record_key == null) ] )
  | ( ([ .[] | select(has("session_id") and .session_id != null) ]
         | group_by(.session_id, .issue, .stage) | map(max_by(.tokens.total)))
      + [ .[] | select((has("session_id") | not) or .session_id == null) ] )
  | ($now | fromdateiso8601) as $nowsec
  | ($nowsec - ($wh * 3600)) as $cutoff
  | [ .[]
      | select((.ts_start // "") != "")
      | { ts: (.ts_start | fromdateiso8601), tot: (.tokens.total // 0) }
      | select(.ts >= $cutoff) ] as $in
  | (($in | map(.tot) | add) // 0) as $sum
  | (if ($in | length) == 0 then "-" else ($in | map(.ts) | min) end) as $earliest
  | "\($sum) \($earliest)"
' "$CAPTURE_LOG" 2>/dev/null)"

WINDOW_SUM="${WINDOW_DATA%% *}"
EARLIEST_EPOCH="${WINDOW_DATA##* }"

# Defensive: if jq failed (malformed log / bad clock) degrade gracefully.
if [ -z "$WINDOW_SUM" ] || ! printf '%s' "$WINDOW_SUM" | grep -qE '^[0-9]+$'; then
  echo "Usage read-out (${WINDOW_HOURS}h window): window=--tok / cap=${CAP_TOKENS}tok — headroom=--tok — throttle-ETA --"
  exit 0
fi

# --- headroom + throttle-ETA projection ---
# headroom = max(0, cap - window_sum). When usage >= cap, ETA "now (cap reached)".
# Otherwise burn_per_hour = window_sum / span_hours, where span_hours =
# min(window_hours, now - earliest-in-window-ts) in hours. ETA minutes =
# headroom / burn_per_hour * 60, rendered "~Nm" (or "~Nh Mm" when >= 60m).
# When window_sum == 0 (no burn) ETA renders "--" (no division by zero).
NOW_EPOCH="$(date -u -d "$NOW" +%s 2>/dev/null || echo "")"

read -r HEADROOM ETA < <(awk \
  -v sum="$WINDOW_SUM" -v cap="$CAP_TOKENS" -v wh="$WINDOW_HOURS" \
  -v earliest="$EARLIEST_EPOCH" -v now="$NOW_EPOCH" '
  BEGIN {
    headroom = cap - sum;
    if (headroom < 0) headroom = 0;

    if (sum >= cap) { print headroom, "now (cap reached)"; exit }
    if (sum <= 0)   { print headroom, "--"; exit }

    # elapsed span in hours, capped at the window length, floored to a small
    # epsilon to avoid div0 when earliest == now.
    span_h = wh;
    if (earliest != "-" && now != "") {
      elapsed_h = (now - earliest) / 3600.0;
      if (elapsed_h < span_h) span_h = elapsed_h;
    }
    if (span_h < 0.0001) span_h = 0.0001;

    burn_per_hour = sum / span_h;
    eta_min = headroom / burn_per_hour * 60.0;
    eta_min_int = int(eta_min + 0.5);

    if (eta_min_int >= 60) {
      h = int(eta_min_int / 60);
      m = eta_min_int % 60;
      printf "%d ~%dh %dm\n", headroom, h, m;
    } else {
      printf "%d ~%dm\n", headroom, eta_min_int;
    }
  }')

echo "Usage read-out (${WINDOW_HOURS}h window): window=${WINDOW_SUM}tok / cap=${CAP_TOKENS}tok — headroom=${HEADROOM}tok — throttle-ETA ${ETA}"
