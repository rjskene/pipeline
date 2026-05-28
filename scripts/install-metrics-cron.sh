#!/bin/bash
set -uo pipefail
#
# install-metrics-cron.sh — DOGFOOD-ONLY crontab line generator (issue #576).
#
# Prints a ready-to-paste crontab line for the daily metrics-snapshot run
# to stdout. Does NOT mutate the operator's crontab; the operator pastes
# manually via `crontab -e`. Matches the "host-local cron, not CI
# workflow" rule from the dogfood-instrumentation memory.
#
# This script is for this repo's own dogfood operation only. It is NOT
# shipped in the plugin manifest.
#
# Usage:
#   bash scripts/install-metrics-cron.sh        # print crontab line
#   bash scripts/install-metrics-cron.sh --help
#

print_usage() {
  cat <<'USAGE'
Usage: install-metrics-cron.sh [--help]

  install-metrics-cron.sh — DOGFOOD-ONLY crontab line generator.

  Prints a crontab line that runs scripts/metrics-snapshot.sh once a day
  at 07:00 local time and tees output to .claude/logs/metrics-snapshot.cron.log.
  The operator pastes the line into `crontab -e` manually; this script
  does not mutate the live crontab.

  --help    Print this banner and exit 0.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) print_usage; exit 0 ;;
    *)
      echo "install-metrics-cron: ERROR: unknown arg: $1" >&2
      exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cat <<EOF
# Paste into \`crontab -e\` to run a daily metrics snapshot at 07:00 local.
# The snapshot is dogfood-only — consumers do not run this.
0 7 * * * cd ${REPO_ROOT} && bash scripts/metrics-snapshot.sh >> .claude/logs/metrics-snapshot.cron.log 2>&1
EOF
