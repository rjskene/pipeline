#!/bin/bash
set -uo pipefail
#
# arm-usage-resume-cron.sh — DOGFOOD-ONLY deterministic spec-emitter for the
# #969 usage-resume re-check cron (issue #1041).
#
# Prints the EXACT CronCreate arming args to stdout and NOTHING ELSE. It has
# NO side effects: it never calls CronCreate, CronList, or CronDelete. Those
# are model-only harness tools — no shell can arm or verify a harness cron.
# The emitter's job is to source the cadence/marker/prompt tokens so the
# model's only action is transcribing the emitted args into ONE CronCreate
# call (a transcription, not a hand-reconstruction from dense prose).
#
# Single mechanism: a turn-INDEPENDENT recurring CronCreate on a fixed
# ~25-min off-minute cadence. There is NO ScheduleWakeup / delay-based
# one-shot branch — a one-shot is turn-coupled and can fire while still
# throttled (R2/R3); only a wall-clock cron self-heals across an account cap.
#
# This script is for this repo's own dogfood operation only. It is NOT
# shipped in the plugin manifest, mirroring scripts/install-metrics-cron.sh.
#
# Usage:
#   bash scripts/arm-usage-resume-cron.sh \
#     --resume-command "/pipeline:fullsend 1041 1042 --campaign" \
#     --resume-at 2026-06-13T18:05Z
#   bash scripts/arm-usage-resume-cron.sh --help
#

# Fixed-not-a-knob: the recurring re-check cadence and the marker. Same
# precedent as the +5 min buffer — hardcoded so no new config knob is born
# (which also dodges the gitignored-pipeline.config bug class, #357).
CRON_SCHEDULE="13,38 * * * *"
CRON_MARKER="usage-resume re-check"

print_usage() {
  cat <<'USAGE'
Usage: arm-usage-resume-cron.sh --resume-command <str> --resume-at <iso> [--help]

  arm-usage-resume-cron.sh — DOGFOOD-ONLY deterministic spec-emitter for the
  #969 usage-resume re-check cron.

  Prints the exact CronCreate arming args (schedule / marker / prompt) to
  stdout. It NEVER calls CronCreate — CronCreate/CronList/CronDelete are
  model-only harness tools; only the model arms the cron, by transcribing
  the emitted args into one CronCreate call.

  Required:
    --resume-command <str>  The verbatim /pipeline:fullsend command being run
                            (e.g. "/pipeline:fullsend 1041 1042 --campaign").
                            Hand over what you are running, NOT a curated
                            "remaining" snapshot — fullsend is label-driven +
                            idempotent, so re-entry skips already-merged work.
    --resume-at <iso>       The gate line's resume_at value (ISO). Carried in
                            the prompt for the R5 blind-backstop branch only.

  --help    Print this banner and exit 0.
USAGE
}

RESUME_COMMAND=""
RESUME_AT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_usage; exit 0 ;;
    --resume-command)
      RESUME_COMMAND="${2-}"; shift 2 || { echo "arm-usage-resume: ERROR: --resume-command needs a value" >&2; exit 2; } ;;
    --resume-at)
      RESUME_AT="${2-}"; shift 2 || { echo "arm-usage-resume: ERROR: --resume-at needs a value" >&2; exit 2; } ;;
    *)
      echo "arm-usage-resume: ERROR: unknown arg: $1" >&2
      exit 2 ;;
  esac
done

if [ -z "$RESUME_COMMAND" ] || [ -z "$RESUME_AT" ]; then
  echo "arm-usage-resume: ERROR: --resume-command and --resume-at are required" >&2
  exit 2
fi

cat <<EOF
# Make ONE CronCreate call with EXACTLY these args (do not hand-edit):
schedule: ${CRON_SCHEDULE}
marker: ${CRON_MARKER}
prompt: |
  usage-resume re-check (armed after a #969 usage pause; resume_at: ${RESUME_AT}).
  This cron is the ONLY resume mechanism — turn-independent, fires on wall-clock.

  Each firing is a deliberately tiny turn:
  1. Run: bash "\${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh"
  2. Relay the emitted gate line, then branch on its decision= token:
     - decision=proceed -> CronList -> match marker "${CRON_MARKER}" ->
       CronDelete self, THEN fire the resume command:
         ${RESUME_COMMAND}
       (resumed after usage pause; delete the usage-resume cron if present —
       idempotent: re-entry re-reads label state and skips merged issues.)
     - decision=pause-5h -> STOP the turn (one line). The cron PERSISTS; the
       next firing re-checks. A firing killed by the account cap self-heals.
     - decision=halt-7d -> CronList -> match marker "${CRON_MARKER}" ->
       CronDelete self, THEN a LOUD report (seven-day %, reset date, exact
       manual resume command). NEVER auto-resume a seven-day trip.
     - decision=skip -> NEVER resume on skip UNLESS now >= resume_at + 10 min
       (resume_at: ${RESUME_AT}) -> treat as proceed (R5 blind backstop).
       Otherwise STOP; the cron persists and the next firing's session
       refreshes creds.
EOF
