#!/bin/bash
# Tests for scripts/derive-pr-title.sh — escaping / normalization behavior.
# See issue #361 for the full rationale (path-escape substrings + unbound-var
# defense). The companion file tests/test-derive-pr-title.sh exercises the
# Conventional-Commits rule table itself.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/derive-pr-title.sh"

PASS=0
FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Block 1 — defensive PIPELINE_REPO under set -u (Task 1 of #361).
# ---------------------------------------------------------------------------
# When the helper is invoked outside a sourced-config environment AND without
# the --title-override/--labels-override short-circuits, it must NOT trip the
# `set -u` unbound-variable trap. Instead it should exit 64 with a controlled
# stderr message naming PIPELINE_REPO.

run_unbound_case() {
  local desc="$1"; shift
  local stderr rc
  local tmp_err
  tmp_err=$(mktemp)
  set +e
  env -i PATH="$PATH" bash "$HELPER" "$@" >/dev/null 2>"$tmp_err"
  rc=$?
  set -e
  stderr=$(cat "$tmp_err"); rm -f "$tmp_err"
  if echo "$stderr" | grep -q "unbound variable"; then
    fail_msg "$desc" "stderr contains 'unbound variable' (set -u trap): '$stderr'"
    return
  fi
  if [ "$rc" -ne 64 ]; then
    fail_msg "$desc" "expected exit 64, got $rc; stderr='$stderr'"
    return
  fi
  if ! echo "$stderr" | grep -q "PIPELINE_REPO"; then
    fail_msg "$desc" "stderr missing 'PIPELINE_REPO': '$stderr'"
    return
  fi
  pass_msg "$desc"
}

run_unbound_case \
  "unbound PIPELINE_REPO with no overrides → controlled exit 64, not set -u trap" \
  999

# Title-override short-circuit must still work when PIPELINE_REPO is unset
# (because the helper never reaches the `gh issue view` call). This is the
# regression-prevention assertion for the override path.
assert_override_works_without_repo() {
  local desc="$1"; shift
  local actual rc
  set +e
  actual=$(env -i PATH="$PATH" bash "$HELPER" "$@" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail_msg "$desc" "expected exit 0, got $rc; stdout='$actual'"
    return
  fi
  if [ "$actual" = "feat(x): y" ]; then
    pass_msg "$desc"
  else
    fail_msg "$desc" "expected 'feat(x): y', got '$actual'"
  fi
}

assert_override_works_without_repo \
  "override path works without PIPELINE_REPO env" \
  999 --title-override 'feat(x): y' --labels-override ''

# ---------------------------------------------------------------------------
# Block 2 — title normalization for path-escape substrings (Task 2 of #361).
# ---------------------------------------------------------------------------
# The helper rewrites the literal substring `../` to `..⁄` (U+2044, FRACTION
# SLASH) on every exit path so the resulting PR title can never trip the
# restrict_paths.py PreToolUse hook when interpolated into `gh pr create
# --title "$PR_TITLE"`. Other shell metachars ($, backticks, single quotes,
# `;`, `&&`) are passed through unchanged — those are the executor's
# here-doc / double-quote boundary's responsibility.

# assert_stdout_eq <desc> <expected> <args...>
assert_stdout_eq() {
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

# Path-escape rewrite: input contains `../`, output replaces it with U+2044
# (UTF-8 bytes e2 81 84). The Conventional-Commits prefix, the #277 family
# marker, and the rest of the summary are byte-identical apart from the swap.
assert_stdout_eq \
  "rewrite: '../' is replaced with U+2044 in passthrough title" \
  $'fix(scope): see ..\xe2\x81\x84sibling/path for context' \
  999 --title-override 'fix(scope): see ../sibling/path for context' --labels-override ''

# Multiple `../` occurrences all get rewritten.
assert_stdout_eq \
  "rewrite: every '../' occurrence is replaced (multiple per title)" \
  $'fix(scope): ..\xe2\x81\x84a and ..\xe2\x81\x84b' \
  999 --title-override 'fix(scope): ../a and ../b' --labels-override ''

# Other shell metachars are NOT mutated by the helper — they survive verbatim
# because the executor's quoting boundary handles them. These four assertions
# pin that contract so a future "harden everything" patch doesn't silently
# break round-trip readability of titles with $, `, ', ;, &&.

assert_stdout_eq \
  "passthrough: dollar interpolation chars survive unchanged" \
  'fix(scope): cost is $TOTAL not $0.99' \
  999 --title-override 'fix(scope): cost is $TOTAL not $0.99' --labels-override ''

assert_stdout_eq \
  "passthrough: backticks survive unchanged" \
  'fix(scope): use `date` to stamp it' \
  999 --title-override 'fix(scope): use `date` to stamp it' --labels-override ''

assert_stdout_eq \
  "passthrough: single quote survives unchanged" \
  "fix(scope): it's a path" \
  999 --title-override "fix(scope): it's a path" --labels-override ''

assert_stdout_eq \
  "passthrough: semicolon and && survive unchanged" \
  'fix(scope): run a; then b && c' \
  999 --title-override 'fix(scope): run a; then b && c' --labels-override ''

# Titles with NO `../` substring must round-trip byte-identical — this is the
# regression-prevention assertion for the existing tests/test-derive-pr-title.sh
# corpus, restated here for fast localized failure if the normalization
# function ever broadens its target set.
assert_stdout_eq \
  "no-op: title without '../' is byte-identical" \
  'feat(execute-issue-plan): derive PR title' \
  999 --title-override 'feat(execute-issue-plan): derive PR title' --labels-override ''

# Path-escape rewrite must apply across all exit paths, not just the
# Conventional-Commits passthrough. Exercise the `bug` label fallback and the
# `enhancement` label fallback so a future regression that re-introduces
# `printf '%s\n' "$TITLE"` (bypassing emit_title) is caught here too.
assert_stdout_eq \
  "rewrite: '../' replaced on bug-label fallback path" \
  $'fix(general): see ..\xe2\x81\x84sibling for context' \
  999 --title-override 'see ../sibling for context' --labels-override 'bug'

assert_stdout_eq \
  "rewrite: '../' replaced on enhancement-label fallback path" \
  $'feat(general): see ..\xe2\x81\x84sibling for context' \
  999 --title-override 'see ../sibling for context' --labels-override 'enhancement'

assert_stdout_eq \
  "rewrite: '../' replaced on bug() → fix() rewrite path" \
  $'fix(install): see ..\xe2\x81\x84sibling' \
  999 --title-override 'bug(install): see ../sibling' --labels-override ''

assert_stdout_eq \
  "rewrite: '../' replaced on chore(general) default path" \
  $'chore(general): see ..\xe2\x81\x84sibling' \
  999 --title-override 'see ../sibling' --labels-override ''

# ---------------------------------------------------------------------------
# Block 3 — SKILL.md normalization-source-of-truth note (Task 3 of #361).
# ---------------------------------------------------------------------------
# The executor's step 9b documents that $PR_TITLE is already normalized by
# scripts/derive-pr-title.sh so reviewers don't have to chase the indirection.
# Grep the SKILL.md text for the canonical sentence shape — this is a docs
# regression-prevention assertion, not a runtime one.

SKILL="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"
if ! grep -qE 'PR_TITLE.*normalized.*derive-pr-title\.sh' "$SKILL"; then
  fail_msg "executor: SKILL.md missing the normalization-source-of-truth note" \
    "expected sentence referencing 'PR_TITLE ... normalized ... derive-pr-title.sh' in step 9b"
else
  pass_msg "executor: SKILL.md step 9b notes PR_TITLE normalization source"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
