#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/probe-a.sh"
out=$(probe_a)
[ "$out" = "a" ] || { echo "FAIL: got $out"; exit 1; }
echo "PASS"
