#!/usr/bin/env bash

clamp() {
  local v=$1 lo=$2 hi=$3
  if (( v < lo )); then
    echo "$lo"
  elif (( v > hi )); then
    echo "$hi"
  else
    echo "$v"
  fi
}
