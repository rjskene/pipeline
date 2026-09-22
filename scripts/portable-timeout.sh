#!/bin/bash
# Cross-platform stand-in for GNU timeout.
# macOS does not ship `timeout`. Homebrew's coreutils names it gtimeout, and
# this machine may have neither. perl is part of macOS and can alarm.
set -euo pipefail

signal=TERM
kill_after=""
while [ $# -gt 0 ]; do
  case "$1" in
    --foreground) shift ;;
    --signal=*) signal="${1#--signal=}"; shift ;;
    --signal) signal="$2"; shift 2 ;;
    --kill-after=*) kill_after="${1#--kill-after=}"; shift ;;
    --kill-after) kill_after="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "portable-timeout: unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 2 ]; then
  echo "usage: portable-timeout [--foreground] [--signal=SIG] [--kill-after=SECS] SECS command..." >&2
  exit 2
fi

secs="$1"
shift

if command -v timeout >/dev/null 2>&1; then
  args=(--signal="$signal")
  [ -n "$kill_after" ] && args+=(--kill-after="$kill_after")
  exec timeout "${args[@]}" "$secs" "$@"
fi

if command -v gtimeout >/dev/null 2>&1; then
  args=(--signal="$signal")
  [ -n "$kill_after" ] && args+=(--kill-after="$kill_after")
  exec gtimeout "${args[@]}" "$secs" "$@"
fi

exec perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
