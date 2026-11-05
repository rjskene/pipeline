#!/bin/bash
# macOS has no GNU timeout. The launcher must still bound a command.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin="$root/scripts/portable-timeout.sh"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if command -v timeout >/dev/null 2>&1; then
  echo "SKIP: GNU timeout is on PATH, this contract is for a Mac without it" >&2
  exit 0
fi

set +e
timeout --foreground --signal=TERM --kill-after=30 2 echo red-should-not-run >/tmp/portable-timeout-red.out 2>/tmp/portable-timeout-red.err
red=$?
set -e
if [ "$red" -eq 0 ]; then
  echo "bare timeout unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q "command not found" /tmp/portable-timeout-red.err; then
  echo "expected command not found, got:" >&2
  cat /tmp/portable-timeout-red.err >&2
  exit 1
fi

out=$("$bin" --foreground --signal=TERM --kill-after=30 2 echo green-ok)
[ "$out" = "green-ok" ]

start=$(date +%s)
set +e
"$bin" --foreground --signal=TERM --kill-after=30 1 sleep 30
killed=$?
set -e
end=$(date +%s)
elapsed=$((end - start))
if [ "$elapsed" -gt 5 ]; then
  echo "sleep 30 was not stopped (elapsed ${elapsed}s, status $killed)" >&2
  exit 1
fi
echo "portable-timeout ok (bare timeout exit $red, sleep status $killed, ${elapsed}s)"
