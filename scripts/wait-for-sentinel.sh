#!/bin/bash
set -euo pipefail

# wait-for-sentinel.sh <file> <token> [--timeout SECONDS]
#
# Poll <file> for <token> with a hard, bounded timeout. This is the sanctioned
# replacement for inline `until grep -q TOKEN file; do sleep N; done` loops,
# which wedge forever if the token never appears.
#
# On success: prints <file> contents with the token line (and blank lines)
#             stripped, then exits 0 — so callers can pipe the result directly.
# On timeout: prints an actionable diagnostic to stderr and exits 1, so the
#             caller's Bash tool surfaces failure instead of hanging.
#
# There is intentionally NO retry-forever fallback: relocating the wedge past
# the timeout would defeat the purpose.

usage() {
  echo "usage: wait-for-sentinel.sh <file> <token> [--timeout SECONDS]" >&2
}

FILE=""
TOKEN=""
TIMEOUT=600
INTERVAL=5

# Parse positional args + optional --timeout.
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      shift
      [ $# -gt 0 ] || { echo "wait-for-sentinel: --timeout requires a value" >&2; usage; exit 2; }
      TIMEOUT="$1"
      ;;
    --timeout=*)
      TIMEOUT="${1#--timeout=}"
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      if [ -z "$FILE" ]; then
        FILE="$1"
      elif [ -z "$TOKEN" ]; then
        TOKEN="$1"
      else
        echo "wait-for-sentinel: unexpected argument '$1'" >&2
        usage; exit 2
      fi
      ;;
  esac
  shift
done

if [ -z "$FILE" ] || [ -z "$TOKEN" ]; then
  echo "wait-for-sentinel: missing required <file> and/or <token>" >&2
  usage
  exit 2
fi

case "$TIMEOUT" in
  ''|*[!0-9]*)
    echo "wait-for-sentinel: --timeout must be a non-negative integer (got '$TIMEOUT')" >&2
    usage
    exit 2
    ;;
esac

emit_filtered() {
  # Strip blank lines and lines that are *exactly* the sentinel token. The
  # token is matched as a fixed whole-line string (-xF), so a real output line
  # that merely contains the token as a substring is preserved. Tolerate the
  # grep exit 1 that occurs when nothing survives the filter.
  grep -vxF -- "$TOKEN" "$FILE" 2>/dev/null | grep -vE '^[[:space:]]*$' || true
}

# The token is matched as a fixed string (-F), never a regex, so a token
# containing regex metacharacters (e.g. v1.0) can't falsely match other lines.
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  if grep -qF -- "$TOKEN" "$FILE" 2>/dev/null; then
    emit_filtered
    exit 0
  fi
  remaining=$((TIMEOUT - elapsed))
  step=$INTERVAL
  [ "$step" -gt "$remaining" ] && step=$remaining
  sleep "$step"
  elapsed=$((elapsed + step))
done

# Final check in case the token landed during the last sleep window.
if grep -qF -- "$TOKEN" "$FILE" 2>/dev/null; then
  emit_filtered
  exit 0
fi

if [ -e "$FILE" ]; then
  exists="yes"
  size=$(wc -c <"$FILE" 2>/dev/null | tr -d ' ')
else
  exists="no"
  size=0
fi
echo "wait-for-sentinel: timed out after ${TIMEOUT}s waiting for token '$TOKEN' in $FILE (file size: ${size} bytes, exists: ${exists})" >&2
exit 1
