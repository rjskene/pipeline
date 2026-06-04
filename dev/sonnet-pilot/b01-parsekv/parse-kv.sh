#!/usr/bin/env bash
# parse-kv.sh — config-file key reader
# Usage: source parse-kv.sh; kv_get <key> <file>
#
# Reads a KEY=VALUE file and echoes the value for <key>.
# Behaviors:
#   - Last assignment wins (mirrors shell sourcing)
#   - Ignores comment lines (first non-whitespace char is '#')
#   - Trims whitespace around key and value
#   - Absent key: prints nothing and returns non-zero exit
#   - Values may contain '='; splits on first '=' only

kv_get() {
  local key="$1"
  local file="$2"
  local found=0
  local result=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip leading whitespace to check for comment
    local stripped="${line#"${line%%[! ]*}"}"
    # Skip comment lines
    [[ "$stripped" == \#* ]] && continue
    # Skip lines with no '='
    [[ "$line" != *=* ]] && continue

    # Split on first '='
    local raw_k="${line%%=*}"
    local raw_v="${line#*=}"

    # Trim whitespace from key
    local k="${raw_k#"${raw_k%%[! ]*}"}"
    k="${k%"${k##*[! ]}"}"

    if [[ "$k" == "$key" ]]; then
      # Trim whitespace from value
      local v="${raw_v#"${raw_v%%[! ]*}"}"
      v="${v%"${v##*[! ]}"}"
      result="$v"
      found=1
    fi
  done <"$file"

  if [[ $found -eq 1 ]]; then
    printf '%s\n' "$result"
    return 0
  else
    return 1
  fi
}
