#!/bin/bash
set -uo pipefail
#
# Tests for scripts/check-conventional-title.sh — the shared Conventional
# Commits PR-title validator used by /pipeline:execute-issue-plan and
# /pipeline:run. See Issue #45.
#
# Asserts:
#   (a) the script exists and is executable
#   (b) sourcing it exposes CONVENTIONAL_TITLE_REGEX
#   (c) sourcing it defines check_conventional_title
#   (d) a matrix of valid/invalid titles is classified correctly via both:
#       - the function (return code, when sourced)
#       - the script (exit code, when run directly)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/check-conventional-title.sh"

PASS=0
FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# (a) Existence + executable bit.
if [ -f "$HELPER" ]; then
  pass_msg "helper exists at scripts/check-conventional-title.sh"
else
  fail_msg "helper exists at scripts/check-conventional-title.sh"
fi

if [ -x "$HELPER" ]; then
  pass_msg "helper is executable"
else
  fail_msg "helper is executable"
fi

# (b) + (c) Sourcing exposes regex var and function. Run in a subshell so a
# failed source doesn't poison the rest of the test.
if [ -f "$HELPER" ]; then
  if ( set +u; source "$HELPER" >/dev/null 2>&1; [ -n "${CONVENTIONAL_TITLE_REGEX:-}" ] ); then
    pass_msg "sourcing exposes CONVENTIONAL_TITLE_REGEX"
  else
    fail_msg "sourcing exposes CONVENTIONAL_TITLE_REGEX"
  fi

  if ( set +u; source "$HELPER" >/dev/null 2>&1; declare -F check_conventional_title >/dev/null ); then
    pass_msg "sourcing defines check_conventional_title function"
  else
    fail_msg "sourcing defines check_conventional_title function"
  fi
fi

# (d) Title matrix.
VALID_TITLES=(
  "feat: add modal"
  "fix: handle null"
  "chore: bump deps"
  "refactor: extract helper"
  "docs: clarify readme"
  "ci: add workflow"
  "perf: cache result"
  "test: cover edge"
  "build: update tsconfig"
  "style: format file"
  "revert: undo PR #123"
  "feat(web): add modal component"
  "fix(audit): distinguish blocked attempts"
  "feat(log_run): use underscore scope"
  "fix(plugin-hooks): hyphen scope"
  "feat(api)!: breaking change"
)

INVALID_TITLES=(
  "Postsearch audit: distinguish BLOCKED attempts from successful peeks"
  "explain_code.py: compact one-row-per-value output by default"
  "sweep tooling: use conventional commit type for data commits"
  "epic(release): roll up v1.0"
  "bug(plan-issue): something"
  "feat add modal"
  "feat(): empty scope"
  "feat:  "
  "Feat: capitalized type"
  "feat(Web): uppercase in scope"
  "unknownType: subject"
  ""
)

run_fn_check() {
  # Run the function in a subshell so an exit/return inside doesn't poison
  # the test harness. Returns 0 if function returns 0, else 1.
  local title="$1"
  ( set +u; source "$HELPER" >/dev/null 2>&1; check_conventional_title "$title" )
}

run_script_check() {
  local title="$1"
  bash "$HELPER" "$title" >/dev/null 2>&1
}

if [ -f "$HELPER" ]; then
  for t in "${VALID_TITLES[@]}"; do
    if run_fn_check "$t"; then
      pass_msg "function accepts: '$t'"
    else
      fail_msg "function accepts: '$t'"
    fi
    if run_script_check "$t"; then
      pass_msg "script accepts:   '$t'"
    else
      fail_msg "script accepts:   '$t'"
    fi
  done

  for t in "${INVALID_TITLES[@]}"; do
    if run_fn_check "$t"; then
      fail_msg "function rejects: '$t'"
    else
      pass_msg "function rejects: '$t'"
    fi
    if run_script_check "$t"; then
      fail_msg "script rejects:   '$t'"
    else
      pass_msg "script rejects:   '$t'"
    fi
  done
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
