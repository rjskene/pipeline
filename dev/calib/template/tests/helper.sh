# shellcheck shell=bash
#
# helper.sh — shared assertions for the tests/case-*.sh files.
#
# A case file sources this, calls t_setup (which points CALIB_HOME at a fresh
# scratch directory), makes assertions, and ends with t_report.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
CALIBCTL="$PROJECT_ROOT/bin/calibctl"

T_PASS=0
T_FAIL=0
T_NAME="$(basename "${0:-case}")"

t_setup() {
  CALIB_HOME="$(mktemp -d)"
  export CALIB_HOME
  trap 't_cleanup' EXIT
}

t_cleanup() {
  [ -n "${CALIB_HOME:-}" ] && rm -rf "$CALIB_HOME"
  return 0
}

t_ok()   { echo "    ok   - $1"; T_PASS=$((T_PASS + 1)); }
t_not_ok() { echo "    NOT OK - $1"; T_FAIL=$((T_FAIL + 1)); }

# calib <args...> — run the CLI under test.
calib() {
  bash "$CALIBCTL" "$@"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    t_ok "$label"
  else
    t_not_ok "$label (expected '$expected', got '$actual')"
  fi
}

assert_rc() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" -eq "$actual" ]; then
    t_ok "$label"
  else
    t_not_ok "$label (expected rc $expected, got $actual)"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    t_ok "$label"
  else
    t_not_ok "$label (output did not contain '$needle')"
  fi
}

assert_match() {
  local haystack="$1" regex="$2" label="$3"
  if printf '%s' "$haystack" | grep -qE -- "$regex"; then
    t_ok "$label"
  else
    t_not_ok "$label (output did not match /$regex/)"
  fi
}

assert_true() {
  local label="$2"
  if [ "$1" = "0" ]; then
    t_ok "$label"
  else
    t_not_ok "$label (expected success)"
  fi
}

t_report() {
  echo "    -- $T_NAME: $T_PASS passed, $T_FAIL failed"
  [ "$T_FAIL" -eq 0 ] || exit 1
  exit 0
}
