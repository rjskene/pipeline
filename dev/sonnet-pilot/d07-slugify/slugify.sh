#!/usr/bin/env bash

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '-'
}
