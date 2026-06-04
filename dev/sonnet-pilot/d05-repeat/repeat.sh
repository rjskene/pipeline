#!/usr/bin/env bash

repeat_str() {
  local s="$1"
  local n="$2"
  local result=""
  local i
  for (( i=0; i<n; i++ )); do
    result="${result}${s}"
  done
  echo "$result"
}
