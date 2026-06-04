#!/usr/bin/env bash

is_even() {
  local n=$1
  [ $(( n % 2 )) -eq 0 ]
}
