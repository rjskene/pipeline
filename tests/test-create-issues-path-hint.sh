#!/bin/bash
set -euo pipefail

# Tests for #759: create-issues emits the advisory <!-- pipeline:path-hint=A|B|C -->
# marker on a clear A/B/C signal. Static-grep, model-facing prose guard
# (pattern of test-create-issues-combine-bias.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="$SCRIPT_DIR/../skills/create-issues/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$FILE" ]; then
  echo "ERROR: create-issues SKILL.md not found at $FILE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Slice the hint subsection: from the `### PATH hint body marker` heading up to
# the next `### ` heading.
HINT_SLICE="$WORKDIR/hint-slice.md"
awk '
  /^### / { if (inblock) exit }
  /^### PATH hint body marker/ { inblock = 1 }
  inblock { print }
' "$FILE" > "$HINT_SLICE"

echo "create-issues path-hint emission guard"

# (i) literal advisory hint marker present.
inc
if grep -qF '<!-- pipeline:path-hint=' "$FILE"; then
  pass_msg "literal <!-- pipeline:path-hint= present"
else
  fail_msg "literal <!-- pipeline:path-hint= missing"
fi

# (ii) hint subsection exists.
inc
if [ -s "$HINT_SLICE" ]; then
  pass_msg "### PATH hint body marker subsection present"
else
  fail_msg "### PATH hint body marker subsection missing"
fi

# (iii) letters set is A/B/C only.
inc
if grep -qE 'A\|B\|C|A/B/C' "$HINT_SLICE"; then
  pass_msg "hint subsection states letters A/B/C"
else
  fail_msg "hint subsection does not state A/B/C letter set"
fi

# (iv) D is NEVER a hint, references authoritative path=D.
inc
if grep -qiE 'never a hint|authoritative' "$HINT_SLICE" && grep -qF 'path=D' "$HINT_SLICE"; then
  pass_msg "subsection states D is never a hint / authoritative path=D"
else
  fail_msg "subsection does not state D-never-a-hint referencing path=D"
fi

# (v) advisory.
inc
if grep -qiF 'advisory' "$HINT_SLICE"; then
  pass_msg "subsection marks the hint advisory"
else
  fail_msg "subsection does not mark the hint advisory"
fi

# (vi) path-agnostic default preserved.
inc
if grep -qiE 'silence = no hint|only on a clear' "$HINT_SLICE" && grep -qiF 'path-agnostic' "$HINT_SLICE"; then
  pass_msg "subsection preserves path-agnostic default (silence = no hint)"
else
  fail_msg "subsection does not state path-agnostic default"
fi

# (vii) distinct-syntax note.
inc
if grep -qF 'path-hint=' "$HINT_SLICE" && grep -qiE 'distinct|different from' "$HINT_SLICE"; then
  pass_msg "subsection notes distinct syntax (path-hint= vs path=)"
else
  fail_msg "subsection does not note distinct syntax"
fi

# (viii) negative: the hint subsection must NOT claim D as a hint value.
inc
if grep -qE 'path-hint=D|hint=.*D.*hint value' "$HINT_SLICE"; then
  fail_msg "hint subsection wrongly references path-hint=D as a hint value"
else
  pass_msg "hint subsection does not claim D as a hint value"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
