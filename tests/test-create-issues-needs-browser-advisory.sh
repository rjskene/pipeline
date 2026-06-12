#!/bin/bash
set -euo pipefail

# Tests for #1015: create-issues emits a filing-time advisory suggesting the
# needs-browser label when the drafted body targets browser-rendered UI
# behaviour. Static-grep, model-facing prose guard (clone of
# test-create-issues-needs-debug-advisory.sh).

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

# Slice the advisory subsection: from the `### needs-browser advisory` heading
# up to the next `### ` heading.
SLICE="$WORKDIR/needs-browser-slice.md"
awk '
  /^### / { if (inblock) exit }
  /^### needs-browser advisory/ { inblock = 1 }
  inblock { print }
' "$FILE" > "$SLICE"

echo "create-issues needs-browser advisory guard"

# (i) advisory subsection exists.
inc
if [ -s "$SLICE" ]; then
  pass_msg "### needs-browser advisory subsection present"
else
  fail_msg "### needs-browser advisory subsection missing"
fi

# (ii) names the needs-browser label.
inc
if grep -qF 'needs-browser' "$SLICE"; then
  pass_msg "subsection names the needs-browser label"
else
  fail_msg "subsection does not name needs-browser"
fi

# (iii) states the conjunction (browser-rendered UI target + user-visible
#       interaction claim + "open page / see Y" acceptance shape).
inc
if grep -qiE 'all (of )?(these|the following)|conjunction|ALL hold' "$SLICE" \
   && grep -qiE 'browser-rendered|browser UI|frontend asset|assets/' "$SLICE" \
   && grep -qiE 'click|keyboard|focus|layout|render' "$SLICE" \
   && grep -qiE 'open page|see Y|acceptance' "$SLICE"; then
  pass_msg "subsection states the UI-target+interaction+open-page conjunction"
else
  fail_msg "subsection does not state the conjunction"
fi

# (iv) lists suppressors (pure-logic/unit/static, server-side, docs).
inc
if grep -qiF 'suppressor' "$SLICE" \
   && grep -qiE 'pure-logic|unit|static' "$SLICE" \
   && grep -qiE 'server-side' "$SLICE" \
   && grep -qiE 'docs' "$SLICE"; then
  pass_msg "subsection lists suppressors (pure-logic/unit/static, server-side, docs)"
else
  fail_msg "subsection does not list the suppressors"
fi

# (v) advisory: default-no, operator-confirm, never auto-apply.
inc
if grep -qiF 'advisory' "$SLICE" \
   && grep -qiE 'default no|y/N|never auto-apply|operator confirm|confirm' "$SLICE"; then
  pass_msg "subsection is advisory (default-no, operator confirm, never auto-apply)"
else
  fail_msg "subsection does not state advisory/default-no/confirm"
fi

# (vi) references the needs-debug advisory as the precedent pattern.
inc
if grep -qiE 'needs-debug advisory|same pattern|precedent' "$SLICE"; then
  pass_msg "subsection references the needs-debug advisory precedent"
else
  fail_msg "subsection does not reference the needs-debug advisory precedent"
fi

# (vii) negative: must NOT fire for docs / pure server-side / pure-logic JS.
inc
if grep -qiE 'never.*docs|not.*docs' "$SLICE" \
   && grep -qiE 'server-side' "$SLICE" \
   && grep -qiE 'pure-logic' "$SLICE"; then
  pass_msg "subsection excludes docs/server-side/pure-logic (never fires)"
else
  fail_msg "subsection does not exclude docs/server-side/pure-logic"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
