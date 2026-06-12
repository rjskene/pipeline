#!/bin/bash
set -euo pipefail

# Tests for #1015: classify-issue carries an autonomous needs-browser backstop
# for externally-filed issues (no operator present). Static-grep, model-facing
# prose guard. The backstop posts an advisory comment and MUST NOT broaden the
# BEGIN-LABEL-APPLY `_safe_label` allow-set {docs-only|multi-task|quick-fix}.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$FILE" ]; then
  echo "ERROR: classify-issue SKILL.md not found at $FILE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Slice the backstop subsection: from a heading naming the needs-browser
# backstop up to the next heading of the same-or-higher level.
SLICE="$WORKDIR/needs-browser-backstop-slice.md"
awk '
  /^#{2,3} / { if (inblock) exit }
  /^#{2,3} .*needs-browser backstop/ { inblock = 1 }
  inblock { print }
' "$FILE" > "$SLICE"

echo "classify-issue needs-browser backstop guard"

# (i) backstop subsection exists.
inc
if [ -s "$SLICE" ]; then
  pass_msg "needs-browser backstop subsection present"
else
  fail_msg "needs-browser backstop subsection missing"
fi

# (ii) names the needs-browser label.
inc
if grep -qF 'needs-browser' "$SLICE"; then
  pass_msg "subsection names the needs-browser label"
else
  fail_msg "subsection does not name needs-browser"
fi

# (iii) autonomous "no operator present" framing — advisory comment path.
inc
if grep -qiE 'no operator|autonomous|externally-filed|external' "$SLICE" \
   && grep -qiE 'advisory comment|post.*comment|comment.*advisory' "$SLICE"; then
  pass_msg "subsection states the autonomous comment-path framing"
else
  fail_msg "subsection does not state autonomous comment-path framing"
fi

# (iv) states the same conjunction (UI/interaction/"see Y") and suppressors.
inc
if grep -qiE 'click|keyboard|focus|layout|render|interaction|open page|see Y' "$SLICE" \
   && grep -qiF 'suppressor' "$SLICE" \
   && grep -qiE 'pure-logic' "$SLICE" \
   && grep -qiE 'server-side' "$SLICE" \
   && grep -qiE 'docs' "$SLICE"; then
  pass_msg "subsection states the conjunction + suppressors"
else
  fail_msg "subsection does not state the conjunction + suppressors"
fi

# (v) negative: does NOT broaden the BEGIN-LABEL-APPLY `_safe_label` allow-set.
#     The allow-set case-arm must remain exactly {docs-only|multi-task|quick-fix}.
inc
if grep -qF 'docs-only|multi-task|quick-fix) return 0' "$FILE" \
   && ! grep -qE 'needs-browser[^`]*return 0|return 0[^`]*needs-browser' "$FILE"; then
  pass_msg "_safe_label allow-set unchanged (needs-browser not added to guardrail)"
else
  fail_msg "_safe_label allow-set was broadened with needs-browser"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
