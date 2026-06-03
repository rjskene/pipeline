#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/probe-c.sh"
out=$(probe_c)
[ "$out" = "c" ] || { echo "FAIL: got $out"; exit 1; }
echo "PASS"
