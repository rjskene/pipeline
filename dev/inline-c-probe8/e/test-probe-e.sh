#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/probe-e.sh"
out=$(probe_e); [ "$out" = "e" ] || { echo "FAIL: got $out"; exit 1; }; echo "PASS"
