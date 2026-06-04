#!/usr/bin/env bash
# semver_cmp <a> <b>
# Compares two major.minor.patch version strings numerically.
# Strips optional leading v/V.
# Echoes: -1 (a<b), 0 (a==b), 1 (a>b)

semver_cmp() {
  local a="${1#[vV]}"
  local b="${2#[vV]}"

  local -a va vb
  IFS='.' read -ra va <<< "$a"
  IFS='.' read -ra vb <<< "$b"

  local i
  for i in 0 1 2; do
    local fa="${va[$i]:-0}"
    local fb="${vb[$i]:-0}"
    if (( 10#$fa < 10#$fb )); then
      echo -1; return
    elif (( 10#$fa > 10#$fb )); then
      echo 1; return
    fi
  done

  echo 0
}
