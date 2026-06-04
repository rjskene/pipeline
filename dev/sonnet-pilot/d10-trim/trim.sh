#!/usr/bin/env bash

trim() {
  local s="$1"
  # strip leading whitespace
  s="${s#"${s%%[! ]*}"}"
  # strip trailing whitespace
  s="${s%"${s##*[! ]}"}"
  echo "$s"
}
