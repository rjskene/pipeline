#!/bin/bash
set -euo pipefail
# Guard (#1335): the "Build a fixture when needed" bullet in
# evaluate-issue-plan and evaluate-issue-pr SKILL.md must prescribe a
# `.claude/scratch`-scoped mktemp AND a literal-path (never-a-variable)
# cleanup instruction — the wording the .claude/scratch carve-out in
# hooks/block_deletions.py (#1335) exists to make safe.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_SKILL="$REPO_ROOT/skills/evaluate-issue-plan/SKILL.md"
PR_SKILL="$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"
ANCHOR="Build a fixture when needed"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

# bullet_line <file> — the single line carrying the ANCHOR bullet.
bullet_line() {
  grep -F -- "$ANCHOR" "$1" | head -1
}

assert_bullet_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  inc
  local line
  line="$(bullet_line "$file")"
  if [ -z "$line" ]; then
    fail_msg "$label (no '$ANCHOR' bullet found in $file)"
  elif printf '%s' "$line" | grep -qF -- "$needle"; then
    pass_msg "$label"
  else
    fail_msg "$label (bullet missing substring: $needle)"
  fi
}

for pair in "evaluate-issue-plan:$PLAN_SKILL" "evaluate-issue-pr:$PR_SKILL"; do
  name="${pair%%:*}"; file="${pair#*:}"
  echo "Fixture-scratch prose — $name"
  assert_bullet_contains "$file" 'mktemp -d -p .claude/scratch' \
    "$name: bullet prescribes mktemp -d -p .claude/scratch"
  assert_bullet_contains "$file" '.claude/scratch/' \
    "$name: bullet names a .claude/scratch/ cleanup path"
  assert_bullet_contains "$file" 'variable' \
    "$name: bullet says cleanup is never through a variable"
  echo ""
done

echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
