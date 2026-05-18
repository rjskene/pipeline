#!/usr/bin/env bash
set -euo pipefail

# Assert mock-web/style.css carries the new blue echo-output color.
# This test exists to satisfy PATH B red→green discipline for issue #260.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CSS="$ROOT/mock-web/style.css"
EXPECTED='#echo-output { font-style: italic; color: #1d4ed8; }'

if ! grep -qF "$EXPECTED" "$CSS"; then
  echo "FAIL: mock-web/style.css does not contain '$EXPECTED'" >&2
  exit 1
fi

echo "PASS: mock-web/style.css contains the expected #echo-output rule"
