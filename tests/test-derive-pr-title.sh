#!/bin/bash
# Tests for scripts/derive-pr-title.sh — the helper that converts an issue
# title + label set into a Conventional-Commits PR title. See issue #56 and
# its approved plan for the derivation rule table (source of truth lives in
# the helper itself).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/derive-pr-title.sh"

PASS=0
FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# assert_stdout <desc> <expected-stdout> <args...>
# Runs the helper with --title-override / --labels-override args and asserts
# exit 0 + exact stdout match.
assert_stdout() {
  local desc="$1"; shift
  local expected="$1"; shift
  local actual rc
  set +e
  actual=$(bash "$HELPER" "$@" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail_msg "$desc" "expected exit 0, got $rc; stdout='$actual'"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    pass_msg "$desc"
  else
    fail_msg "$desc" "expected '$expected', got '$actual'"
  fi
}

# assert_refusal <desc> <args...>
# Asserts exit 2, empty stdout, and stderr matches both refusal phrases.
assert_refusal() {
  local desc="$1"; shift
  local stdout stderr rc
  local tmp_err
  tmp_err=$(mktemp)
  set +e
  stdout=$(bash "$HELPER" "$@" 2>"$tmp_err")
  rc=$?
  set -e
  stderr=$(cat "$tmp_err"); rm -f "$tmp_err"
  if [ "$rc" -ne 2 ]; then
    fail_msg "$desc" "expected exit 2, got $rc"
    return
  fi
  if [ -n "$stdout" ]; then
    fail_msg "$desc" "expected empty stdout, got '$stdout'"
    return
  fi
  if ! echo "$stderr" | grep -q "is a tracker"; then
    fail_msg "$desc" "stderr missing 'is a tracker': '$stderr'"
    return
  fi
  if ! echo "$stderr" | grep -q "Close the issue or rename it"; then
    fail_msg "$desc" "stderr missing 'Close the issue or rename it': '$stderr'"
    return
  fi
  pass_msg "$desc"
}

# Task 1: passthrough — title already conforms to Conventional Commits.
assert_stdout \
  "passthrough: feat(scope): ... is returned verbatim" \
  "feat(execute-issue-plan): derive PR title" \
  999 --title-override 'feat(execute-issue-plan): derive PR title' --labels-override ''

# Task 2: epic-prefix issues are trackers and must be refused.
assert_refusal \
  "refusal: epic(scope) title exits 2 with tracker stderr" \
  999 --title-override 'epic(redline): tracker for #1, #2' --labels-override ''

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
