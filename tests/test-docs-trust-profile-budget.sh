#!/bin/bash
set -euo pipefail
# Guard: #1291's trust-profile documentation is deliberately BUDGETED prose.
# docs/cost-architecture.md section 9 gets exactly ONE paragraph line naming the
# knob and both resolver effects; docs/calibration.md's `--profile` sentence must
# describe what the flag actually sets (PIPELINE_TRUST_PROFILE in the sandbox
# session) rather than the pre-#1291 "evaluator strictness" framing, which never
# matched the implementation. The two blocks summed are capped at 150 words: if
# this test fails on the budget, cut prose — never raise the ceiling.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COST="$ROOT/docs/cost-architecture.md"
CALIB="$ROOT/docs/calibration.md"
BUDGET=150

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

echo "docs/cost-architecture.md — section 9 trust-profile paragraph"

# (1) exactly one paragraph line, placed inside section 9.
s9_count="$(grep -cF -- '**Trust profile (#1291)' "$COST" || true)"
inc
if [ "$s9_count" = "1" ]; then
  pass_msg "exactly one '**Trust profile (#1291)' line"
else
  fail_msg "expected exactly 1 '**Trust profile (#1291)' line, found $s9_count"
fi

s9_line="$(grep -nF -- '**Trust profile (#1291)' "$COST" | head -1 | cut -d: -f1 || true)"
h9_line="$(grep -nE '^## 9\.' "$COST" | head -1 | cut -d: -f1 || true)"
map_line="$(grep -nE '^## Issue map' "$COST" | head -1 | cut -d: -f1 || true)"
inc
if [ -n "$s9_line" ] && [ -n "$h9_line" ] && [ -n "$map_line" ] \
   && [ "$s9_line" -gt "$h9_line" ] && [ "$s9_line" -lt "$map_line" ]; then
  pass_msg "paragraph sits between the '## 9.' heading and '## Issue map'"
else
  fail_msg "paragraph is not between '## 9.' and '## Issue map' (para=${s9_line:-none} s9=${h9_line:-none} map=${map_line:-none})"
fi

s9_text=""
if [ -n "$s9_line" ]; then s9_text="$(sed -n "${s9_line}p" "$COST")"; fi
for needle in 'PIPELINE_TRUST_PROFILE' 'lean-single' 'SKIP=true' 'plan-eval skipped: lean profile'; do
  inc
  if printf '%s' "$s9_text" | grep -qF -- "$needle"; then
    pass_msg "paragraph names '$needle'"
  else
    fail_msg "paragraph does not name '$needle'"
  fi
done

echo ""
echo "docs/calibration.md — --profile sets PIPELINE_TRUST_PROFILE"

# (2) one blank-line-delimited paragraph carries both the flag and the knob.
para_count="$(awk 'BEGIN{RS=""} /--profile/ && /PIPELINE_TRUST_PROFILE/ {n++} END{print n+0}' "$CALIB")"
inc
if [ "$para_count" -ge 1 ]; then
  pass_msg "a paragraph names both '--profile' and 'PIPELINE_TRUST_PROFILE'"
else
  fail_msg "no paragraph names both '--profile' and 'PIPELINE_TRUST_PROFILE'"
fi
calib_para="$(awk 'BEGIN{RS=""} /--profile/ && /PIPELINE_TRUST_PROFILE/ {print; exit}' "$CALIB")"

inc
if grep -qF -- 'evaluator strictness' "$CALIB"; then
  fail_msg "still frames --profile as 'evaluator strictness'"
else
  pass_msg "no longer frames --profile as 'evaluator strictness'"
fi

echo ""
echo "trust-profile prose budget (<= $BUDGET words summed)"

s9_words="$(printf '%s\n' "$s9_text" | wc -w)"
calib_words="$(printf '%s\n' "$calib_para" | wc -w)"
total_words=$((s9_words + calib_words))

inc
if [ "$s9_words" -ge 1 ]; then
  pass_msg "section 9 paragraph is non-empty ($s9_words words)"
else
  fail_msg "section 9 paragraph is empty"
fi

inc
if [ "$calib_words" -ge 1 ]; then
  pass_msg "calibration paragraph is non-empty ($calib_words words)"
else
  fail_msg "calibration paragraph is empty"
fi

inc
if [ "$total_words" -le "$BUDGET" ]; then
  pass_msg "summed budget $total_words/$BUDGET words"
else
  fail_msg "summed budget blown: $total_words/$BUDGET words (cut prose, never raise the ceiling)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
