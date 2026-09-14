#!/bin/bash
set -uo pipefail
# Prose pin for #1329: the #1322 CI-is-the-oracle rule must define "subject"
# (execute-issue-plan Step 6b), require the PRE-EXISTING: list in the PR body
# (Step 6b rule + Step 9b template), and evaluate-issue-pr must run the subject
# check over that list. Region-scoped (mirrors
# tests/test-execute-skill-testwait-synchronous.sh); needle match uses `case`
# glob, never `<pipe> grep -q` (SIGPIPE false-absents — see tests/_lib/skill-body.sh).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/skills/execute-issue-plan/SKILL.md"
EVAL="$ROOT/skills/evaluate-issue-pr/SKILL.md"
source "$ROOT/tests/_lib/skill-body.sh"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }
for f in "$EXEC" "$EVAL"; do [ -f "$f" ] || { echo "FAIL: $f not found" >&2; exit 1; }; done

STEP6B="$(awk '/^\s*\*\*6b\. Run tests/{c=1} /^\s*\*\*6c\./{c=0} c' "$EXEC")"
STEP9="$(awk '/^9\. \*\*Open a pull request/{c=1} /^10\. \*\*Mark as pr-open/{c=0} c' "$EXEC")"
SCOPE="$(grep -F -- '- **Scope at pr-eval time.**' "$EVAL")"
[ -n "$STEP6B" ] || { echo "FAIL: Step 6b region empty (markers moved?)" >&2; exit 1; }
[ -n "$STEP9" ]  || { echo "FAIL: Step 9 region empty (markers moved?)" >&2; exit 1; }
[ -n "$SCOPE" ]  || { echo "FAIL: Scope-at-pr-eval bullet not found" >&2; exit 1; }

# assert_in <label> <region-text> <needle> — literal substring, no pipe.
assert_in() {
  local label="$1" region="$2" needle="$3"; inc
  case "$region" in
    *"$needle"*) pass_msg "$label: contains \"$needle\"" ;;
    *)           fail_msg "$label: missing \"$needle\"" ;;
  esac
}

echo "execute-issue-plan Step 6b"
assert_in "exec-6b-1322-rule"    "$STEP6B" 'CI is the oracle for untouched failures:'
assert_in "exec-6b-subject-def"  "$STEP6B" '**Subject:**'
assert_in "exec-6b-subject-verbs" "$STEP6B" 'reads, greps, sources or execs a touched path'
assert_in "exec-6b-subject-glob" "$STEP6B" 'glob/directory'
assert_in "exec-6b-subject-check" "$STEP6B" 'grep -rlF -e <basename> -e <dir>/ tests/'
assert_in "exec-6b-never-preexisting" "$STEP6B" 'A failing subject test is never `PRE-EXISTING:`'
assert_in "exec-6b-body-heading"  "$STEP6B" '## Pre-existing failures'
assert_in "exec-6b-body-none"     "$STEP6B" 'PRE-EXISTING: none'

echo "execute-issue-plan Step 9b PR-body template"
assert_in "exec-9b-heading" "$STEP9" '## Pre-existing failures'
assert_in "exec-9b-none"    "$STEP9" 'PRE-EXISTING: none'

echo "evaluate-issue-pr Scope-at-pr-eval bullet"
assert_in "eval-1322-rule"   "$SCOPE" 'CI is the oracle for pre-existing failures:'
assert_in "eval-list-check"  "$SCOPE" 'list check (#1329):**'
assert_in "eval-body-heading" "$SCOPE" '## Pre-existing failures'
assert_in "eval-subject-check" "$SCOPE" 'grep -F -e <basename> -e <dir>/ <test>'
assert_in "eval-listed-flagged" "$SCOPE" 'A listed subject test is Flagged'
assert_in "eval-missing-flagged" "$SCOPE" 'without the list is Flagged'

# Body-scoped sanity: the frontmatter alone must not satisfy the heading pin.
inc
if skill_body_has "$EXEC" '## Pre-existing failures'; then pass_msg "exec-body-scoped heading"; else fail_msg "exec-body-scoped heading (only in frontmatter?)"; fi

echo ""; echo "  $TESTS tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
