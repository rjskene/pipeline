# shellcheck shell=bash
#
# report.sh — the human-readable summary rendered by `calibctl report`.
#
# The report is deliberately plain text (no colour, no tables) so it stays
# diffable in CI logs.
#
# Depends on lib/store.sh; source it first.

report__count_status() {
  store_rows "$1" "" | grep -c '' || true
}

report__count_priority() {
  store_rows all "$1" | grep -c '' || true
}

report__oldest_open() {
  store_rows open "" | head -n1
}

report_render() {
  local open done total high med low oldest
  open="$(report__count_status open)"
  done="$(report__count_status done)"
  total="$(report__count_status all)"
  high="$(report__count_priority high)"
  med="$(report__count_priority med)"
  low="$(report__count_priority low)"

  printf 'Task report\n'
  printf '===========\n'
  printf 'open       %s\n' "$open"
  printf 'done       %s\n' "$done"
  printf 'total      %s\n' "$total"
  printf '\n'
  printf 'by priority\n'
  printf '  high     %s\n' "$high"
  printf '  med      %s\n' "$med"
  printf '  low      %s\n' "$low"

  oldest="$(report__oldest_open)"
  if [ -n "$oldest" ]; then
    printf '\n'
    printf 'oldest open: #%s %s\n' \
      "$(store_field "$oldest" 1)" "$(store_field "$oldest" 6)"
  fi
}
