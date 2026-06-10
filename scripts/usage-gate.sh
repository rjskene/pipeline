#!/bin/bash
set -uo pipefail
#
# usage-gate.sh — usage-aware pause/resume gate (issue #969).
#
# Pure READER + DECISION over the OAuth usage endpoint behind Claude Code's
# /usage panel (https://api.anthropic.com/api/oauth/usage). No writes, no
# scheduling, no label changes — the script decides, SKILL.md prose obeys
# (same pattern as auto-merge-gate.sh). Spec:
# docs/superpowers/specs/2026-06-10-usage-gate-design.md
#
# Output contract: exactly ONE stdout line, ALWAYS exit 0 (fail-open — the
# gate must never block a run on its own failure):
#
#   usage-gate: decision=<tok>[ reason=<r>] five_hour=<N%|--> seven_day=<N%|--> threshold=<N> resume_at=<ISO8601|-->
#
# Decision order (first match wins):
#   1. PIPELINE_USAGE_GATE_ENABLED=false          -> skip reason=disabled
#   2. creds missing/unreadable or token absent   -> skip reason=no-credentials
#   3. curl/network failure                       -> skip reason=fetch-error
#      HTTP non-200                               -> skip reason=http-<code>
#      malformed/unparseable body                 -> skip reason=parse-error
#   4. seven_day.utilization >= threshold         -> halt-7d   (wins over 5h)
#   5. five_hour.utilization >= threshold         -> pause-5h
#      (resume_at = five_hour.resets_at + 5 min — fixed buffer, not a knob)
#   6. otherwise                                  -> proceed
#
# SECURITY: the bearer token lives in a shell variable only — never echoed,
# never logged, never placed on a process argv (curl reads it via --config on
# stdin, so it cannot surface in /proc/*/cmdline). NEVER add `set -x` here.
# tests/test-usage-gate.sh greps stdout+stderr for a canary token.
#
# NOT dogfood-gated: no PIPELINE_LOGS_ENABLED dependency. API-key installs
# (no ~/.claude/.credentials.json) degrade to skip reason=no-credentials.

print_usage() {
  cat <<'USAGE'
Usage: usage-gate.sh [--fixture PATH] [--now ISO8601] [--threshold N]
                     [--credentials PATH] [--help]

  usage-gate.sh — usage-aware pause/resume gate (issue #969).

  Reads real account usage from the OAuth usage endpoint and emits ONE
  decision line (proceed | pause-5h | halt-7d | skip). ALWAYS exits 0:
  every error path degrades to `skip reason=<r>` (fail-open).

  --fixture PATH      Canned endpoint JSON response; replaces ONLY the
                      network fetch (the credentials check still runs first).
  --now ISO8601       Injected clock for deterministic tests
                      (default: current UTC time).
  --threshold N       Override threshold percent (default:
                      $PIPELINE_USAGE_GATE_THRESHOLD_PCT or 85; both windows).
  --credentials PATH  Override creds path
                      (default: ~/.claude/.credentials.json).
  --help              Print this banner and exit 0.
USAGE
}

FIXTURE=""
NOW=""
THRESHOLD_FLAG=""
CREDENTIALS="${HOME}/.claude/.credentials.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)        print_usage; exit 0 ;;
    --fixture)        FIXTURE="${2:-}"; shift 2 ;;
    --fixture=*)      FIXTURE="${1#--fixture=}"; shift ;;
    --now)            NOW="${2:-}"; shift 2 ;;
    --now=*)          NOW="${1#--now=}"; shift ;;
    --threshold)      THRESHOLD_FLAG="${2:-}"; shift 2 ;;
    --threshold=*)    THRESHOLD_FLAG="${1#--threshold=}"; shift ;;
    --credentials)    CREDENTIALS="${2:-}"; shift 2 ;;
    --credentials=*)  CREDENTIALS="${1#--credentials=}"; shift ;;
    *)
      echo "usage-gate: WARN: unknown arg: $1 (ignored)" >&2
      shift
      ;;
  esac
done

# Threshold precedence: --threshold > PIPELINE_USAGE_GATE_THRESHOLD_PCT > 85.
# Non-numeric values degrade to the default (fail-open, never fatal).
THRESHOLD="${THRESHOLD_FLAG:-${PIPELINE_USAGE_GATE_THRESHOLD_PCT:-85}}"
if ! printf '%s' "$THRESHOLD" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
  echo "usage-gate: WARN: non-numeric threshold '$THRESHOLD'; using 85" >&2
  THRESHOLD="85"
fi

NOW="${NOW:-$(date -u +%FT%TZ)}"

FIVE_HOUR_PCT="--"
SEVEN_DAY_PCT="--"
RESUME_AT="--"

# emit <decision> [reason] — render the single contract line and exit 0.
# The ONLY stdout writer in this script.
emit() {
  local decision="$1" reason="${2:-}"
  local reason_field=""
  [ -n "$reason" ] && reason_field=" reason=${reason}"
  echo "usage-gate: decision=${decision}${reason_field} five_hour=${FIVE_HOUR_PCT} seven_day=${SEVEN_DAY_PCT} threshold=${THRESHOLD} resume_at=${RESUME_AT}"
  exit 0
}

# --- 1. kill switch ---------------------------------------------------------
if [ "${PIPELINE_USAGE_GATE_ENABLED:-true}" = "false" ]; then
  emit "skip" "disabled"
fi

# --- 2. credentials (runs BEFORE the fixture branch by design: every fixture
#        test exercises the token-handling path the canary grep audits) -------
if [ ! -r "$CREDENTIALS" ]; then
  emit "skip" "no-credentials"
fi
TOKEN="$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS" 2>/dev/null)"
if [ -z "$TOKEN" ]; then
  emit "skip" "no-credentials"
fi

# --- 3. fetch (fixture replaces ONLY this step) ------------------------------
BODY_TMP="$(mktemp)"
trap 'rm -f "$BODY_TMP"' EXIT

if [ -n "$FIXTURE" ]; then
  if ! cat "$FIXTURE" > "$BODY_TMP" 2>/dev/null; then
    emit "skip" "fetch-error"
  fi
else
  # Token passed via --config on stdin: never on argv, never in /proc/*/cmdline.
  HTTP_CODE="$(curl -sS --max-time 15 -o "$BODY_TMP" -w '%{http_code}' --config - 2>/dev/null <<EOF
url = "https://api.anthropic.com/api/oauth/usage"
header = "Authorization: Bearer ${TOKEN}"
header = "anthropic-beta: oauth-2025-04-20"
EOF
)"
  CURL_RC=$?
  if [ "$CURL_RC" -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
    emit "skip" "fetch-error"
  fi
  if [ "$HTTP_CODE" != "200" ]; then
    emit "skip" "http-${HTTP_CODE}"
  fi
fi

# --- parse ------------------------------------------------------------------
PARSED="$(jq -r '[
    (.five_hour.utilization // "missing"),
    (.five_hour.resets_at // "missing"),
    (.seven_day.utilization // "missing")
  ] | @tsv' "$BODY_TMP" 2>/dev/null)"
if [ -z "$PARSED" ]; then
  emit "skip" "parse-error"
fi
IFS=$'\t' read -r FIVE_HOUR_UTIL FIVE_HOUR_RESETS_AT SEVEN_DAY_UTIL <<<"$PARSED"

num_re='^[0-9]+(\.[0-9]+)?$'
if ! printf '%s' "$FIVE_HOUR_UTIL" | grep -qE "$num_re" \
  || ! printf '%s' "$SEVEN_DAY_UTIL" | grep -qE "$num_re" \
  || [ "$FIVE_HOUR_RESETS_AT" = "missing" ] || [ -z "$FIVE_HOUR_RESETS_AT" ]; then
  emit "skip" "parse-error"
fi

FIVE_HOUR_PCT="$(awk -v v="$FIVE_HOUR_UTIL" 'BEGIN{printf "%g%%", v}')"
SEVEN_DAY_PCT="$(awk -v v="$SEVEN_DAY_UTIL" 'BEGIN{printf "%g%%", v}')"

# --- 4/5/6. decide (float compare; boundary == trips, >=) --------------------
DECISION="$(awk -v fh="$FIVE_HOUR_UTIL" -v sd="$SEVEN_DAY_UTIL" -v t="$THRESHOLD" 'BEGIN{
  if (sd >= t)      print "halt-7d";
  else if (fh >= t) print "pause-5h";
  else              print "proceed";
}')"

if [ "$DECISION" = "pause-5h" ]; then
  # resume_at = five_hour.resets_at + 5 minutes (fixed buffer, not a knob).
  RESUME_AT="$(date -u -d "${FIVE_HOUR_RESETS_AT} + 5 minutes" +%FT%TZ 2>/dev/null)"
  if [ -z "$RESUME_AT" ]; then
    RESUME_AT="--"
    emit "skip" "parse-error"
  fi
fi

emit "$DECISION"
