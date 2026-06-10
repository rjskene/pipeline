#!/bin/bash
set -euo pipefail

# Tests for #998: create-issues emits a filing-time advisory suggesting the
# needs-debug label for undiagnosed non-trivial defects. Static-grep,
# model-facing prose guard (pattern of test-create-issues-path-hint.sh).

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

# Slice the advisory subsection: from the `### needs-debug advisory` heading
# up to the next `### ` heading.
SLICE="$WORKDIR/needs-debug-slice.md"
awk '
  /^### / { if (inblock) exit }
  /^### needs-debug advisory/ { inblock = 1 }
  inblock { print }
' "$FILE" > "$SLICE"

echo "create-issues needs-debug advisory guard"

# (i) advisory subsection exists.
inc
if [ -s "$SLICE" ]; then
  pass_msg "### needs-debug advisory subsection present"
else
  fail_msg "### needs-debug advisory subsection missing"
fi

# (ii) names the needs-debug label.
inc
if grep -qF 'needs-debug' "$SLICE"; then
  pass_msg "subsection names the needs-debug label"
else
  fail_msg "subsection does not name needs-debug"
fi

# (iii) states the four-way conjunction (defect + symptom + cause-absent + amplifier).
inc
if grep -qiE 'all (of )?(these|the following)|four-way|conjunction|ALL hold' "$SLICE" \
   && grep -qiF 'symptom' "$SLICE" \
   && grep -qiE 'amplifier' "$SLICE" \
   && grep -qiE 'cause is absent|cause.*absent|no.*root cause|undiagnosed' "$SLICE"; then
  pass_msg "subsection states the defect+symptom+cause-absent+amplifier conjunction"
else
  fail_msg "subsection does not state the four-way conjunction"
fi

# (iv) lists suppressors reusing the PATH D lexicon.
inc
if grep -qiF 'suppressor' "$SLICE" \
   && grep -qiE 'typo|one-line|trivial|obvious' "$SLICE"; then
  pass_msg "subsection lists suppressors with PATH D lexicon"
else
  fail_msg "subsection does not list suppressors / PATH D lexicon"
fi

# (v) advisory: default-no, operator-confirm, never auto-apply.
inc
if grep -qiF 'advisory' "$SLICE" \
   && grep -qiE 'default no|y/N|never auto-apply|operator confirm|confirm' "$SLICE"; then
  pass_msg "subsection is advisory (default-no, operator confirm, never auto-apply)"
else
  fail_msg "subsection does not state advisory/default-no/confirm"
fi

# (vi) references the PATH D filing-time backstop as the precedent pattern.
inc
if grep -qiE 'PATH D|backstop|same pattern|precedent' "$SLICE"; then
  pass_msg "subsection references the PATH D backstop precedent"
else
  fail_msg "subsection does not reference the PATH D backstop"
fi

# (vii) negative: must NOT fire for feat/docs.
inc
if grep -qiE 'never feat|not feat|feat or docs|never.*docs' "$SLICE"; then
  pass_msg "subsection excludes feat/docs (never fires)"
else
  fail_msg "subsection does not exclude feat/docs"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
