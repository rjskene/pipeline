#!/usr/bin/env bash
# #1462 — plan-eval executable verification runs EXISTING artifacts only.
#
# Shape checks on the `## Executable verification` section of
# skills/evaluate-issue-plan/SKILL.md (tokens only, no prose pinning):
#   1. the section carries the `not-executed: proposed artifact` token;
#   2. the plan-eval scope bullet (clause (b)) contains `never`;
#   3. a write-arm sentence names `--dry-run` or `fixture`.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/evaluate-issue-plan/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

section=$(awk '/^## Executable verification/{f=1; print; next} f && /^## /{exit} f' "$SKILL")
if [ -n "$section" ]; then
  pass_msg "found ## Executable verification section"
else
  fail_msg "## Executable verification section missing"
fi

if grep -qF 'not-executed: proposed artifact' <<<"$section"; then
  pass_msg "section carries the 'not-executed: proposed artifact' token"
else
  fail_msg "section lacks the 'not-executed: proposed artifact' token"
fi

scope=$(grep -F '**Scope at plan-eval time.**' <<<"$section")
if [ -z "$scope" ]; then
  fail_msg "scope-at-plan-eval-time bullet missing"
elif grep -qE '\(b\).*[Nn]ever' <<<"$scope"; then
  pass_msg "clause (b) of the scope bullet contains 'never'"
else
  fail_msg "clause (b) of the scope bullet lacks 'never'"
fi

writearm=$(grep -iE 'write[- ]arm' <<<"$section")
if [ -z "$writearm" ]; then
  fail_msg "no write-arm sentence in section"
elif grep -qE -- '--dry-run|fixture' <<<"$writearm"; then
  pass_msg "write-arm sentence names --dry-run or fixture"
else
  fail_msg "write-arm sentence names neither --dry-run nor fixture"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
