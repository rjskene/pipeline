#!/bin/bash
set -euo pipefail

# Static-grep tests for Proposal A in #354: broadened PATH D keyword list,
# size heuristic row, alternative-bullet rule, acceptance-criteria skip rule,
# and flip/swap code-token co-occurrence rule. All assertions inspect
# skills/classify-issue/SKILL.md.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: classify-issue SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Extract "step 4" region: from `^4\. ` to `^4a\.` (the score table + new prose
# bullets land between these markers).
STEP4_SLICE="$WORKDIR/step4.md"
awk '
  /^4\. / { inblock = 1 }
  /^4a\./ { inblock = 0 }
  inblock { print }
' "$SKILL_FILE" > "$STEP4_SLICE"

if [ ! -s "$STEP4_SLICE" ]; then
  echo "ERROR: could not slice step 4 from SKILL.md (no content between ^4. and ^4a.)" >&2
  # Don't exit; let the assertions FAIL loudly.
fi

# Extract the D-row of the rule table. The new D row is the one ending with
# `| D | medium |` and containing the broadened keyword list. There may be
# multiple `| D |` rows (size heuristic, explicit label) — for keyword
# assertions we grep the entire step-4 slice.

# --- Test 1: every new D-keyword appears in the step-4 slice ---
echo "Test 1: broadened D-row keywords present in step 4"
KEYWORDS=(
  "single-line"
  "single-file"
  "single-subsystem"
  "narrow fix"
  "minimal"
  "trivial"
  "obvious"
  "~N LOC"
  "no design choice"
  "single condition"
  "one regex"
  "flip"
  "swap"
  "repoint"
  "toggle"
)
for kw in "${KEYWORDS[@]}"; do
  inc
  if grep -qF -- "$kw" "$STEP4_SLICE"; then
    pass_msg "keyword present: $kw"
  else
    fail_msg "missing D-row keyword: $kw"
  fi
done

# --- Test 2: size-heuristic row exists with both phrases ---
echo "Test 2: size-heuristic row exists with lean-D and lean-B phrases"
inc
if grep -qF -- "one file + ≤ ~20 LOC" "$STEP4_SLICE"; then
  pass_msg "size heuristic — lean D phrase present"
else
  fail_msg "size heuristic — missing phrase: one file + ≤ ~20 LOC"
fi

inc
if grep -qF -- "≤ 3 files + ≤ ~40 LOC" "$STEP4_SLICE"; then
  pass_msg "size heuristic — lean B phrase present"
else
  fail_msg "size heuristic — missing phrase: ≤ 3 files + ≤ ~40 LOC"
fi

# --- Test 3: alternative-bullet rule disambiguation ---
echo "Test 3: alternative-bullet disambiguation prose"
inc
if grep -qiF "alternative" "$STEP4_SLICE"; then
  pass_msg "step 4 mentions 'alternative'"
else
  fail_msg "step 4 does not mention 'alternative'"
fi

inc
if grep -qiE "options:|either|choose one|pick one" "$STEP4_SLICE"; then
  pass_msg "step 4 mentions one of options:/either/choose one/pick one"
else
  fail_msg "step 4 missing any of options:/either/choose one/pick one"
fi

inc
if grep -qiE "one work item|not N" "$STEP4_SLICE"; then
  pass_msg "step 4 says alternatives count as one work item / not N"
else
  fail_msg "step 4 missing phrase 'one work item' or 'not N'"
fi

# --- Test 4: acceptance-criteria skip rule ---
echo "Test 4: acceptance-criteria skip rule"
inc
if grep -qi "Acceptance" "$STEP4_SLICE" && grep -qiE "skip|do not count" "$STEP4_SLICE"; then
  pass_msg "step 4 documents Acceptance + skip/do not count"
else
  fail_msg "step 4 missing Acceptance + skip/do not count rule"
fi

# --- Test 5: flip/swap code-token co-occurrence rule ---
echo "Test 5: flip/swap code-token co-occurrence rule"
inc
# Look for a line in step 4 mentioning flip OR swap together with one of
# file path / function name / backtick / `code`
if awk '
  /flip|swap/ && (/file path/ || /function name/ || /backtick/ || /`code`/) { found = 1 }
  END { exit (found ? 0 : 1) }
' "$STEP4_SLICE"; then
  pass_msg "flip/swap co-occurrence rule references code-shaped token"
else
  fail_msg 'no flip/swap rule co-occurring with file path/function name/backtick/`code`'
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
