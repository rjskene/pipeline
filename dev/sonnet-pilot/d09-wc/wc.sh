#!/usr/bin/env bash

count_words() {
  local s="$1"
  if [ -z "$s" ]; then
    echo 0
  else
    echo "$s" | wc -w
  fi
}
