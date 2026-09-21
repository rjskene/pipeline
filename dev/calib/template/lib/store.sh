# shellcheck shell=bash
#
# store.sh — the file-backed task store.
#
# Records live in a single tab-separated file, one task per line:
#
#   id <TAB> status <TAB> priority <TAB> created <TAB> tags <TAB> title
#
# `status`   is one of open|done
# `priority` is one of low|med|high
# `created`  is an ISO-8601 UTC timestamp
# `tags`     is a comma-separated list (possibly empty)
# `title`    is free text with tabs/newlines squashed out
#
# Every mutating helper serialises through lib/lock.sh so two concurrent
# `calibctl` invocations cannot interleave a read-modify-write.

CALIB_STATUS_OPEN="open"
CALIB_STATUS_DONE="done"

# Root directory for all mutable state. Overridable so the test suite (and the
# reference tests in the calibration slate) can point at a scratch directory.
store_home() {
  printf '%s\n' "${CALIB_HOME:-$PWD/.calib}"
}

store_path() {
  printf '%s\n' "$(store_home)/tasks.tsv"
}

store_init() {
  local dir file
  dir="$(store_home)"
  file="$(store_path)"
  [ -d "$dir" ] || mkdir -p "$dir"
  [ -f "$file" ] || : > "$file"
}

# Squash the characters that would corrupt the record format.
store__clean() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | sed -e 's/[[:space:]]\{2,\}/ /g' -e 's/^ //' -e 's/ $//'
}

store_next_id() {
  local file
  file="$(store_path)"
  [ -f "$file" ] || { printf '1\n'; return 0; }
  awk -F'\t' 'BEGIN { max = 0 } $1 + 0 > max { max = $1 + 0 } END { print max + 1 }' "$file"
}

# store_add <title> [priority] [tags] -> prints the new id
store_add() {
  local title="$1" priority="${2:-med}" tags="${3:-}"
  local id created file
  store_init
  file="$(store_path)"
  title="$(store__clean "$title")"
  tags="$(store__clean "$tags")"
  id="$(with_lock store store_next_id)"
  created="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$CALIB_STATUS_OPEN" "$priority" "$created" "$tags" "$title" >> "$file"
  printf '%s\n' "$id"
}

# store_rows [status] [priority] — status may be "all" (or empty) to skip the
# status filter; priority may be empty to skip the priority filter.
store_rows() {
  local status="${1:-all}" priority="${2:-}"
  local file
  file="$(store_path)"
  [ -f "$file" ] || return 0
  awk -F'\t' -v want_status="$status" -v want_priority="$priority" '
    want_status != "" && want_status != "all" && $2 != want_status { next }
    want_priority != "" && $3 != want_priority { next }
    { print }
  ' "$file"
}

# store_get <id> — prints the matching row, rc 1 when there is no such task.
store_get() {
  local id="$1" file row
  file="$(store_path)"
  [ -f "$file" ] || return 1
  row="$(awk -F'\t' -v id="$id" '$1 == id { print; exit }' "$file")"
  [ -n "$row" ] || return 1
  printf '%s\n' "$row"
}

store_field() {
  local row="$1" n="$2"
  printf '%s' "$row" | cut -d"$(printf '\t')" -f"$n"
}

# store_set_status <id> <status> — rc 1 when the task does not exist.
store_set_status() {
  local id="$1" status="$2"
  store_get "$id" >/dev/null || return 1
  with_lock store store__rewrite_status "$id" "$status"
}

store__rewrite_status() {
  local id="$1" status="$2" file tmp
  file="$(store_path)"
  tmp="$file.$$.tmp"
  awk -F'\t' -v OFS='\t' -v id="$id" -v status="$status" \
    '$1 == id { $2 = status } { print }' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# store_count [status] — number of rows matching the status filter.
store_count() {
  store_rows "${1:-all}" "" | grep -c '' || true
}
