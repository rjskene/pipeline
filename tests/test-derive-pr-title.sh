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

# Task 3: the `tracker` label is a secondary signal — refuse even when the
# title has no epic() prefix.
assert_refusal \
  "refusal: tracker label exits 2 even without epic title" \
  999 --title-override 'Something descriptive' --labels-override 'tracker'

# Task 4: bug(<scope>): ... → fix(<scope>): ... with scope normalization.
assert_stdout \
  "rewrite: bug(install) -> fix(install)" \
  "fix(install): X breaks Y" \
  999 --title-override 'bug(install): X breaks Y' --labels-override ''

assert_stdout \
  "rewrite: bug(Install_Path) lowercases scope, preserves underscores" \
  "fix(install_path): X" \
  999 --title-override 'bug(Install_Path): X' --labels-override ''

# Task 5: `bug` label fallback — no bug() prefix, take scope from title
# parenthetical (if any) else `general`; strip `prefix:` from summary.
assert_stdout \
  "bug label: no parenthetical → general scope, full title as summary" \
  "fix(general): Postsearch audit: distinguish BLOCKED from peeks" \
  999 --title-override 'Postsearch audit: distinguish BLOCKED from peeks' --labels-override 'bug'

assert_stdout \
  "bug label: parenthetical in title wins for scope" \
  "fix(audit): Crash in (audit): something" \
  999 --title-override 'Crash in (audit): something' --labels-override 'bug'

assert_stdout \
  "bug label: strips 'prefix:' from summary" \
  "fix(general): fix the thing" \
  999 --title-override 'skill: fix the thing' --labels-override 'bug'

# Task 6: `enhancement` label fallback — same shape as bug label, emits feat.
assert_stdout \
  "enhancement label: no prefix → feat(general) with full title" \
  "feat(general): Add modal for X" \
  999 --title-override 'Add modal for X' --labels-override 'enhancement'

assert_stdout \
  "enhancement label: strips 'web modal:' prefix; multi-label list" \
  "feat(general): add support for X" \
  999 --title-override 'web modal: add support for X' --labels-override 'enhancement,priority/P1'

# Task 7: no signal → default chore(general).
assert_stdout \
  "default fallback: chore(general) when no prefix/bug/enhancement signal" \
  "chore(general): random title with no prefix" \
  999 --title-override 'random title with no prefix' --labels-override 'priority/P2'

# Task 8 (#507): non-canonical conventional-commit types normalize the type
# while preserving the author's scope, instead of double-prefixing to
# chore(general): <verbatim>.
assert_stdout \
  "non-canonical type with scope, no label -> chore(<scope>)" \
  "chore(visual-proof): exercise visual-proof end-to-end" \
  999 --title-override 'dogfood(visual-proof): exercise visual-proof end-to-end' --labels-override ''

assert_stdout \
  "non-canonical type with scope + enhancement label -> feat(<scope>)" \
  "feat(visual-proof): X" \
  999 --title-override 'dogfood(visual-proof): X' --labels-override 'enhancement'

assert_stdout \
  "non-canonical type with scope + bug label -> fix(<scope>)" \
  "fix(visual-proof): X" \
  999 --title-override 'dogfood(visual-proof): X' --labels-override 'bug'

assert_stdout \
  "idempotent double-prefix strip: chore(general): dogfood(visual-proof): X -> chore(visual-proof): X" \
  "chore(visual-proof): X" \
  999 --title-override 'chore(general): dogfood(visual-proof): X' --labels-override ''

assert_stdout \
  "non-canonical type with no scope (no parentheses) -> existing default fallback chore(general)" \
  "chore(general): X" \
  999 --title-override 'dogfood: X' --labels-override ''

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
