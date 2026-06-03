#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/probe-d.sh"
out=$(probe_d); [ "$out" = "d" ] || { echo "FAIL: got $out"; exit 1; }; echo "PASS"
