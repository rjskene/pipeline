# shellcheck shell=bash
#
# validate.sh — input validation for the CLI surface.
#
# Every helper prints a human-readable message on stderr and returns
# CALIB_RC_USAGE (2) when the input is rejected, so `bin/calibctl` can simply
# do `validate_x "$v" || exit $?`.

CALIB_RC_USAGE=2
CALIB_MAX_TITLE=120

validate__reject() {
  printf 'calibctl: %s\n' "$1" >&2
  return "$CALIB_RC_USAGE"
}

validate_title() {
  local title="$1" trimmed
  trimmed="$(printf '%s' "$title" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -z "$trimmed" ]; then
    validate__reject "invalid title: must not be empty"
    return $?
  fi
  if [ "${#trimmed}" -gt "$CALIB_MAX_TITLE" ]; then
    validate__reject "invalid title: longer than $CALIB_MAX_TITLE characters"
    return $?
  fi
  return 0
}

validate_priority() {
  local priority="$1"
  case "$priority" in
    low|med|high) return 0 ;;
    *) validate__reject "invalid priority: '$priority' (expected low, med or high)"; return $? ;;
  esac
}

validate_status() {
  local status="$1"
  case "$status" in
    open|done|all) return 0 ;;
    *) validate__reject "invalid status: '$status' (expected open, done or all)"; return $? ;;
  esac
}

# A task id is a positive integer, exactly as minted by store_next_id.
validate_id() {
  local id="$1"
  if [[ "$id" =~ [0-9]+ ]]; then
    return 0
  fi
  validate__reject "invalid id: '$id' (expected a positive integer)"
  return $?
}

validate_tags() {
  local tags="$1"
  if printf '%s' "$tags" | grep -q '[[:space:]]'; then
    validate__reject "invalid tags: '$tags' (use a comma-separated list, no spaces)"
    return $?
  fi
  return 0
}
