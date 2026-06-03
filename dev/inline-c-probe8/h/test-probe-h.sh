#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/probe-h.sh"
out=$(probe_h); [ "$out" = "h" ] || { echo "FAIL: got $out"; exit 1; }; echo "PASS"
