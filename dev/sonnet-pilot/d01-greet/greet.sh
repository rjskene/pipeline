#!/usr/bin/env bash

greet() {
  local name="${1:-world}"
  echo "hello, $name"
}
