# shellcheck shell=bash
#
# lock.sh — a tiny advisory lock built on `mkdir`, which is atomic on every
# filesystem calibctl cares about.
#
# Locks live under <store home>/locks/<name>.lock. A lock older than
# CALIB_LOCK_STALE seconds (default 30) is considered abandoned and is
# reclaimed, so a crashed process cannot wedge the CLI forever.
#
# Depends on lib/store.sh for store_home(); source store.sh first.

CALIB_RC_LOCK=3

lock_root() {
  printf '%s\n' "${CALIB_LOCK_ROOT:-$(store_home)/locks}"
}

lock_path() {
  printf '%s\n' "$(lock_root)/$1.lock"
}

lock__age_seconds() {
  local path="$1" now mtime
  now="$(date '+%s')"
  mtime="$(date -r "$path" '+%s' 2>/dev/null || printf '%s' "$now")"
  printf '%s\n' "$(( now - mtime ))"
}

lock__reap_if_stale() {
  local path="$1" stale age
  stale="${CALIB_LOCK_STALE:-30}"
  [ -d "$path" ] || return 0
  age="$(lock__age_seconds "$path")"
  if [ "$age" -ge "$stale" ]; then
    rm -rf "$path"
  fi
}

# lock_acquire <name> [timeout_seconds] — rc CALIB_RC_LOCK on timeout.
lock_acquire() {
  local name="$1" timeout="${2:-${CALIB_LOCK_TIMEOUT:-5}}"
  local path deadline
  path="$(lock_path "$name")"
  mkdir -p "$(lock_root)"
  deadline=$(( $(date '+%s') + timeout ))
  while :; do
    lock__reap_if_stale "$path"
    if mkdir "$path" 2>/dev/null; then
      printf '%s\n' "$$" > "$path/owner"
      return 0
    fi
    [ "$(date '+%s')" -lt "$deadline" ] || return "$CALIB_RC_LOCK"
    sleep 0.1
  done
}

lock_release() {
  local name="$1" path
  path="$(lock_path "$name")"
  rm -rf "$path"
}

lock_held() {
  [ -d "$(lock_path "$1")" ]
}

# with_lock <name> <command> [args...] — run a command under the named lock and
# propagate its exit status.
with_lock() {
  local name="$1"; shift
  local rc=0
  lock_acquire "$name" || return "$CALIB_RC_LOCK"
  "$@" || rc=$?
  lock_release "$name"
  return "$rc"
}
