#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/probe-f.sh"
out=$(probe_f); [ "$out" = "f" ] || { echo "FAIL: got $out"; exit 1; }; echo "PASS"
