#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/probe-g.sh"
out=$(probe_g); [ "$out" = "g" ] || { echo "FAIL: got $out"; exit 1; }; echo "PASS"
