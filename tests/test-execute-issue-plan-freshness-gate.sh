#!/bin/bash
# Contract test for the post-plan freshness STOP-gate (Step 4b) in
# skills/execute-issue-plan/SKILL.md. See issue #716.
#
# This is a docs/contract test: it greps the SKILL.md prose to assert the
# repo-wrap freshness gate exists, is wired to scripts/check-post-plan-freshness.sh,
# names the STOP-on-stale remediation, is positioned between Step 4 (mark
# in-progress) and Step 5 (implement), and passes --base "$PIPELINE_BASE_BRANCH".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  echo "FATAL: SKILL.md not found at $SKILL" >&2
  exit 1
fi

# --- line offsets of the three structural headings -----------------------
# Step 4 = "Mark as in-progress"; 4b = freshness gate; Step 5 = "Implement".
step4_line=$(grep -n '^4\. \*\*Mark as in-progress' "$SKILL" | head -1 | cut -d: -f1)
step4b_line=$(grep -n '^4b\. \*\*Post-plan freshness gate' "$SKILL" | head -1 | cut -d: -f1)
step5_line=$(grep -n '^5\. \*\*Implement the approved plan' "$SKILL" | head -1 | cut -d: -f1)

# Assertion 1: a 4b step heading referencing freshness/staleness exists.
if [ -n "$step4b_line" ]; then
  pass_msg "Step 4b freshness-gate heading present"
else
  fail_msg "Step 4b freshness-gate heading present" "no '4b. **Post-plan freshness gate' heading found"
fi

# Bound the 4b region: from the 4b heading up to (but not including) Step 5.
region=""
if [ -n "$step4b_line" ] && [ -n "$step5_line" ]; then
  region=$(sed -n "${step4b_line},$((step5_line - 1))p" "$SKILL")
fi

# Assertion 2: the step invokes check-post-plan-freshness.sh.
if printf '%s' "$region" | grep -q 'check-post-plan-freshness\.sh'; then
  pass_msg "4b region invokes check-post-plan-freshness.sh"
else
  fail_msg "4b region invokes check-post-plan-freshness.sh" "no check-post-plan-freshness.sh reference in 4b region"
fi

# Assertion 3a: STOP on a stale result (exit code 3).
if printf '%s' "$region" | grep -q 'STOP' \
   && printf '%s' "$region" | grep -Eq '(exit )?3'; then
  pass_msg "4b region specifies STOP on stale (exit 3)"
else
  fail_msg "4b region specifies STOP on stale (exit 3)" "missing STOP token and/or exit-3 mention in 4b region"
fi

# Assertion 3b: names the remediation (re-run after rebase).
if printf '%s' "$region" | grep -Eqi 'rebase' \
   && printf '%s' "$region" | grep -Eqi 're-?run'; then
  pass_msg "4b region names the rebase + re-run remediation"
else
  fail_msg "4b region names the rebase + re-run remediation" "missing 'rebase' and/or 're-run' in 4b region"
fi

# Assertion 4: 4b is positioned AFTER Step 4 and BEFORE Step 5.
if [ -n "$step4_line" ] && [ -n "$step4b_line" ] && [ -n "$step5_line" ] \
   && [ "$step4_line" -lt "$step4b_line" ] && [ "$step4b_line" -lt "$step5_line" ]; then
  pass_msg "Step 4 < Step 4b < Step 5 ordering"
else
  fail_msg "Step 4 < Step 4b < Step 5 ordering" \
    "offsets: step4=$step4_line step4b=$step4b_line step5=$step5_line"
fi

# Assertion 5: the gate passes --base "$PIPELINE_BASE_BRANCH".
if printf '%s' "$region" | grep -q -- '--base "\$PIPELINE_BASE_BRANCH"'; then
  pass_msg "4b region passes --base \"\$PIPELINE_BASE_BRANCH\""
else
  fail_msg "4b region passes --base \"\$PIPELINE_BASE_BRANCH\"" "no --base \"\$PIPELINE_BASE_BRANCH\" in 4b region"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
