#!/bin/bash
set -euo pipefail
# Contract guard: skills/visual-proof-from-plan/SKILL.md must exist with the
# required frontmatter, headings (in spec), JSON contract literal, and a
# reference to references/predicate-syntax.md (which must also exist).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/visual-proof-from-plan/SKILL.md"
REF="$REPO_ROOT/skills/visual-proof-from-plan/references/predicate-syntax.md"
FILE="$SKILL"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

assert_file_exists() {
  local path="$1"; local label="$2"
  inc
  if [ -f "$path" ]; then
    pass_msg "$label"
  else
    fail_msg "$label (missing file: $path)"
  fi
}

assert_contains() {
  local needle="$1"; local label="$2"
  inc
  if [ -f "$FILE" ] && grep -qF -- "$needle" "$FILE"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

echo "visual-proof-from-plan skill contract"

assert_file_exists "$SKILL" "SKILL.md exists"

assert_contains "name: visual-proof-from-plan" "frontmatter name"

assert_contains "## Boot" "heading Boot"
assert_contains "## Contract" "heading Contract"
assert_contains "## Predicate grammar" "heading Predicate grammar"
assert_contains "## Steps" "heading Steps"
assert_contains "## Constraints" "heading Constraints"

assert_contains '"satisfied"' "JSON contract satisfied key"
assert_contains '"unsatisfied"' "JSON contract unsatisfied key"

assert_contains "references/predicate-syntax.md" "references predicate-syntax.md"

assert_file_exists "$REF" "references/predicate-syntax.md exists"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
