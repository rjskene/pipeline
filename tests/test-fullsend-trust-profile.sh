#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-trust-profile.sh — issue #1291.
#
# #1291 gives fullsend the READ SITE for the trust profile resolved upstream by
# scripts/_trust-profile.sh + the two resolvers:
#
#   Step 2 — when `PLAN_EVAL_SPEC` carries `SKIP=true` (lean profile, non-W2
#            PATH A/D), fullsend must NOT dispatch the plan evaluator: it flips
#            `plan-pending -> plan-approved` itself and posts the audit comment
#            `plan-eval skipped: lean profile`.
#   Step 6 — one `TRUST-PROFILE:` run-log line per issue, so a calibration run
#            can attribute spend to the profile that produced it.
#
# Both directives are ONE PHYSICAL LINE each, carrying the shared sentinel
#
#     **Trust profile (#1291):**
#
# which is what makes the extraction below unambiguous on lines that already
# carry other bolded directives.
#
# BUDGET (A4): the two sentinel lines summed are capped at 120 words. This file
# is the only thing pinning the prose size of this change — if it overruns, CUT
# THE PROSE, never raise the ceiling. The `1 <=` floor is paired with the
# ceiling because `wc -w` of a missing extract is 0, which satisfies any ceiling
# and turns the assertion into a silent vacuous pass.
#
# A5 is the blast-radius guard: pr-eval depth (W3) is explicitly NOT part of
# #1291, so the inline PR-eval dispatch prompt contract region must stay free of
# every #1291 token, and the pr-eval stage pin must still resolve. Its region
# extractor is copied VERBATIM from tests/test-fullsend-headless-contract.sh so
# both guards agree on the region boundary.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FULLSEND="$ROOT/skills/fullsend/SKILL.md"

SENTINEL='**Trust profile (#1291):**'
STEP2_ANCHOR='2. **Evaluate plans**'
STEP3_ANCHOR='3. **Re-plan loop**'
ROUTING_ANCHOR='**Per-path execute MODEL routing'
GRAMMAR='TRUST-PROFILE: profile=<p> issue=#N split_role=<bool> plan_eval=<run|skip>'
PREVAL_PIN='resolve-stage-model.sh" <N> pr-eval'

MAX_WORDS=120

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

echo "fullsend trust profile read site (#1291)"

if [ ! -f "$FULLSEND" ]; then
  echo "ERROR: required file not found: $FULLSEND" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Region extractors.
# ---------------------------------------------------------------------------

# The inline PR-EVAL dispatch prompt contract paragraph — the analogue of the
# above. The `   **` terminator alone does not close this one (the paragraph is
# followed by the numbered step `7b.`, which is not indented), so the numbered-
# step start is a second terminator. Without it the "region" runs 178 lines and
# swallows step 7b's fenced block, which would make co-occurrence assertions
# satisfiable by prose that is nowhere near the contract.
preval_contract_region() {
  awk '
    /\*\*Inline PR-eval dispatch prompt contract \(mandatory\)\.\*\*/ { inblock = 1; print; next }
    inblock && (/^   \*\*/ || /^[0-9]+[a-z]?\. /) { inblock = 0 }
    inblock { print }
  ' "$1"
}

# Line number of the first line containing a FIXED string; empty if absent.
first_line_of() { grep -nF -m1 -- "$1" "$FULLSEND" | cut -d: -f1; }

SENT_LINES=()
while IFS= read -r n; do
  [ -n "$n" ] && SENT_LINES+=("$n")
done < <(grep -nF -- "$SENTINEL" "$FULLSEND" | cut -d: -f1)

S1="${SENT_LINES[0]-}"
S2="${SENT_LINES[1]-}"
S1_TEXT=""
S2_TEXT=""
[ -n "$S1" ] && S1_TEXT="$(sed -n "${S1}p" "$FULLSEND")"
[ -n "$S2" ] && S2_TEXT="$(sed -n "${S2}p" "$FULLSEND")"

STEP2_LINE="$(first_line_of "$STEP2_ANCHOR")"
STEP3_LINE="$(first_line_of "$STEP3_ANCHOR")"
ROUTING_LINE="$(first_line_of "$ROUTING_ANCHOR")"

# ---------------------------------------------------------------------------
scenario "A1: the sentinel appears on exactly two lines"

SENT_COUNT="$(grep -cF -- "$SENTINEL" "$FULLSEND")"
inc
if [ "$SENT_COUNT" -eq 2 ]; then
  pass_msg "A1: exactly 2 lines carry '$SENTINEL'"
else
  fail_msg "A1: expected exactly 2 lines carrying '$SENTINEL', found $SENT_COUNT"
fi

# ---------------------------------------------------------------------------
scenario "A2: the Step 2 directive honours plan-eval SKIP=true"

for lit in 'SKIP=true' 'plan-approved' 'plan-pending' 'plan-eval skipped: lean profile'; do
  inc
  if [ -n "$S1_TEXT" ] && grep -qF -- "$lit" <<<"$S1_TEXT"; then
    pass_msg "A2: first sentinel line names '$lit'"
  else
    fail_msg "A2: first sentinel line does not name '$lit'"
  fi
done

inc
if [ -n "$S1" ] && [ -n "$STEP2_LINE" ] && [ "$S1" -gt "$STEP2_LINE" ]; then
  pass_msg "A2: first sentinel line ($S1) is below '$STEP2_ANCHOR' ($STEP2_LINE)"
else
  fail_msg "A2: first sentinel line (${S1:-none}) is not below '$STEP2_ANCHOR' (${STEP2_LINE:-none})"
fi

inc
if [ -n "$S1" ] && [ -n "$STEP3_LINE" ] && [ "$S1" -lt "$STEP3_LINE" ]; then
  pass_msg "A2: first sentinel line ($S1) is above '$STEP3_ANCHOR' ($STEP3_LINE)"
else
  fail_msg "A2: first sentinel line (${S1:-none}) is not above '$STEP3_ANCHOR' (${STEP3_LINE:-none})"
fi

# ---------------------------------------------------------------------------
scenario "A3: the Step 6 directive pins the TRUST-PROFILE log grammar"

inc
if [ -n "$S2_TEXT" ] && grep -qF -- "$GRAMMAR" <<<"$S2_TEXT"; then
  pass_msg "A3: second sentinel line carries the log grammar verbatim"
else
  fail_msg "A3: second sentinel line does not carry '$GRAMMAR'"
fi

inc
if [ -n "$S2_TEXT" ] && grep -qF -- 'lean-single' <<<"$S2_TEXT"; then
  pass_msg "A3: second sentinel line names 'lean-single'"
else
  fail_msg "A3: second sentinel line does not name 'lean-single'"
fi

inc
if [ -n "$S2" ] && [ -n "$ROUTING_LINE" ] && [ "$S2" -gt "$ROUTING_LINE" ]; then
  pass_msg "A3: second sentinel line ($S2) is below '$ROUTING_ANCHOR' ($ROUTING_LINE)"
else
  fail_msg "A3: second sentinel line (${S2:-none}) is not below '$ROUTING_ANCHOR' (${ROUTING_LINE:-none})"
fi

# ---------------------------------------------------------------------------
scenario "A4: prose budget — the two directives sum to <= $MAX_WORDS words"

W1="$(wc -w <<<"$S1_TEXT" | tr -d ' ')"
W2="$(wc -w <<<"$S2_TEXT" | tr -d ' ')"
WORDS=$((W1 + W2))

inc
if [ "$WORDS" -ge 1 ] && [ "$WORDS" -le "$MAX_WORDS" ]; then
  pass_msg "A4: the two sentinel lines sum to $WORDS words (1..$MAX_WORDS)"
else
  fail_msg "A4: the two sentinel lines sum to $WORDS words, outside 1..$MAX_WORDS — cut prose, never raise the ceiling"
fi

# ---------------------------------------------------------------------------
scenario "A5: pr-eval depth (W3) is untouched"

PREVAL="$(preval_contract_region "$FULLSEND")"

inc
if [ -n "$PREVAL" ]; then
  pass_msg "A5: the PR-eval dispatch prompt contract region extracts non-empty"
else
  fail_msg "A5: the PR-eval dispatch prompt contract region is EMPTY (marker moved?) — every A5 predicate below is vacuous"
fi

for banned in 'TRUST-PROFILE' 'lean profile'; do
  inc
  if grep -qF -- "$banned" <<<"$PREVAL"; then
    fail_msg "A5: the PR-eval dispatch prompt contract region names '$banned' — #1291 must not reach pr-eval"
  else
    pass_msg "A5: the PR-eval dispatch prompt contract region does not name '$banned'"
  fi
done

inc
if grep -qF -- "$PREVAL_PIN" "$FULLSEND"; then
  pass_msg "A5: the pr-eval stage pin ('$PREVAL_PIN') is unchanged"
else
  fail_msg "A5: the pr-eval stage pin ('$PREVAL_PIN') is GONE"
fi

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
