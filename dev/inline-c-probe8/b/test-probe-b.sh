#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/probe-b.sh"
out=$(probe_b); [ "$out" = "b" ] || { echo "FAIL: got $out"; exit 1; }; echo "PASS"
