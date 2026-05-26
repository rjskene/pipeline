#!/bin/bash
set -uo pipefail
#
# visual-proof-port-broker.sh — allocate a host port for an inline browser-eval
# `python3 -m http.server` instance. Single-purpose helper for the inline
# evaluator-dispatch path introduced by #517.
#
# Argv:
#   $1  slate_index  (required; non-negative integer)
#   $2  slate_width  (optional; default 0 — collapses PID-dispersion term)
#
# Env:
#   PIPELINE_VISUAL_PROOF_PORT_BASE  (default 8080)
#
# Output (stdout):
#   PORT=<n>
#
# Formula:
#   PID_LOW_BITS = $$ & 0xFFFF
#   PORT = PORT_BASE + slate_index + (PID_LOW_BITS % 100) * slate_width
#
# When slate_width is omitted (or 0) the PID-dispersion term collapses to 0,
# yielding the simple per-slate allocation `PORT_BASE + slate_index`. The
# PID-mod term is the collision-avoidance hedge for concurrent fullsend
# invocations on the same host (see Issue #517 "Concurrent fullsend port
# overlap" error-handling clause).
#
# Exit codes:
#   0  success — PORT emitted on stdout.
#   2  invalid input (negative slate_index).

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <slate_index> [<slate_width>]" >&2
  exit 2
fi

slate_index="$1"
slate_width="${2:-0}"

# Reject negative slate_index. Bash arithmetic happily handles negatives,
# but the contract demands exit 2.
case "$slate_index" in
  -*)
    echo "ERROR: slate_index must be non-negative (got: $slate_index)" >&2
    exit 2
    ;;
esac

PORT_BASE="${PIPELINE_VISUAL_PROOF_PORT_BASE:-8080}"
PID_LOW_BITS=$(( $$ & 0xFFFF ))

PORT=$(( PORT_BASE + slate_index + (PID_LOW_BITS % 100) * slate_width ))

echo "PORT=${PORT}"
