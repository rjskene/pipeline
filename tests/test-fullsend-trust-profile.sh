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

_FS_SKILL="$ROOT/skills/fullsend/SKILL.md"
# #1444 — fullsend's conditional detail was relocated OUT of the hot path into
# skills/fullsend/references/*.md. This guard pins CONTRACT prose, not the file
# a clause happens to live in, so it reads the UNION of SKILL.md and its
# references; SKILL.md comes first, so every step-skeleton region extractor
# below still terminates inside the SKILL.md half.
_FS_UNION_DIR="$(mktemp -d)"
trap 'rm -rf "$_FS_UNION_DIR"' EXIT
FULLSEND="$_FS_UNION_DIR/fullsend-union.md"
cat "$_FS_SKILL" "$ROOT/skills/fullsend"/references/*.md > "$FULLSEND"


SENTINEL='**Trust profile (#1291):**'
STEP2_ANCHOR='2. **Evaluate plans**'
STEP3_ANCHOR='3. **Re-plan loop**'
ROUTING_ANCHOR='**Per-path execute MODEL routing'
# #1429 plan gate — its own sentinel, its own 120-word budget (B-series below).
PG_SENTINEL='**Plan gate (#1429):**'
STEP4_ANCHOR='4. **Approve**'
PG_MAX_WORDS=120
# #1420 removed the split-role lane, so the logged grammar drops `split_role=`.
GRAMMAR='TRUST-PROFILE: profile=<p> issue=#N plan_eval=<run|skip> plan_gate=<full|single|none> plan_rounds=<k>'
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
STEP4_LINE="$(first_line_of "$STEP4_ANCHOR")"

PG_LINES=()
while IFS= read -r n; do
  [ -n "$n" ] && PG_LINES+=("$n")
done < <(grep -nF -- "$PG_SENTINEL" "$FULLSEND" | cut -d: -f1)

P1="${PG_LINES[0]-}"
P2="${PG_LINES[1]-}"
P1_TEXT=""
P2_TEXT=""
[ -n "$P1" ] && P1_TEXT="$(sed -n "${P1}p" "$FULLSEND")"
[ -n "$P2" ] && P2_TEXT="$(sed -n "${P2}p" "$FULLSEND")"

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
scenario "B1: the plan-gate sentinel appears on exactly two lines"

PG_COUNT="$(grep -cF -- "$PG_SENTINEL" "$FULLSEND")"
inc
if [ "$PG_COUNT" -eq 2 ]; then
  pass_msg "B1: exactly 2 lines carry '$PG_SENTINEL'"
else
  fail_msg "B1: expected exactly 2 lines carrying '$PG_SENTINEL', found $PG_COUNT"
fi

# ---------------------------------------------------------------------------
scenario "B2: the Step 2 directive consumes the resolver's GATE= token"

for lit in 'GATE=none' 'GATE=single' 'GATE=full' 'plan-eval skipped: plan-gate=none' 'plan_eval=skip'; do
  inc
  if [ -n "$P1_TEXT" ] && grep -qF -- "$lit" <<<"$P1_TEXT"; then
    pass_msg "B2: first plan-gate line names '$lit'"
  else
    fail_msg "B2: first plan-gate line does not name '$lit'"
  fi
done

inc
if [ -n "$P1" ] && [ -n "$STEP2_LINE" ] && [ "$P1" -gt "$STEP2_LINE" ]; then
  pass_msg "B2: first plan-gate line ($P1) is below '$STEP2_ANCHOR' ($STEP2_LINE)"
else
  fail_msg "B2: first plan-gate line (${P1:-none}) is not below '$STEP2_ANCHOR' (${STEP2_LINE:-none})"
fi

inc
if [ -n "$P1" ] && [ -n "$STEP3_LINE" ] && [ "$P1" -lt "$STEP3_LINE" ]; then
  pass_msg "B2: first plan-gate line ($P1) is above '$STEP3_ANCHOR' ($STEP3_LINE)"
else
  fail_msg "B2: first plan-gate line (${P1:-none}) is not above '$STEP3_ANCHOR' (${STEP3_LINE:-none})"
fi

# ---------------------------------------------------------------------------
scenario "B3: the Step 3 directive caps the re-plan loop under GATE=single"

# 'plan-approved'/'plan-pending' are load-bearing, not decoration: the single-gate
# Revise arm approves HERE because evaluate-issue-plan leaves a Revise verdict at
# `plan-pending` and Step 4's approve site filters on `plan-reviewed` — an arm
# that says "approve" without naming the transition drops the issue out of the
# execute slate silently.
for lit in 'GATE=single' '#1317' 'plan-approved' 'plan-pending'; do
  inc
  if [ -n "$P2_TEXT" ] && grep -qF -- "$lit" <<<"$P2_TEXT"; then
    pass_msg "B3: second plan-gate line names '$lit'"
  else
    fail_msg "B3: second plan-gate line does not name '$lit'"
  fi
done

inc
if [ -n "$P2" ] && [ -n "$STEP3_LINE" ] && [ "$P2" -gt "$STEP3_LINE" ]; then
  pass_msg "B3: second plan-gate line ($P2) is below '$STEP3_ANCHOR' ($STEP3_LINE)"
else
  fail_msg "B3: second plan-gate line (${P2:-none}) is not below '$STEP3_ANCHOR' (${STEP3_LINE:-none})"
fi

inc
if [ -n "$P2" ] && [ -n "$STEP4_LINE" ] && [ "$P2" -lt "$STEP4_LINE" ]; then
  pass_msg "B3: second plan-gate line ($P2) is above '$STEP4_ANCHOR' ($STEP4_LINE)"
else
  fail_msg "B3: second plan-gate line (${P2:-none}) is not above '$STEP4_ANCHOR' (${STEP4_LINE:-none})"
fi

# ---------------------------------------------------------------------------
scenario "B4: prose budget — the two plan-gate directives sum to <= $PG_MAX_WORDS words"

PW1="$(wc -w <<<"$P1_TEXT" | tr -d ' ')"
PW2="$(wc -w <<<"$P2_TEXT" | tr -d ' ')"
PG_WORDS=$((PW1 + PW2))

inc
if [ "$PG_WORDS" -ge 1 ] && [ "$PG_WORDS" -le "$PG_MAX_WORDS" ]; then
  pass_msg "B4: the two plan-gate lines sum to $PG_WORDS words (1..$PG_MAX_WORDS)"
else
  fail_msg "B4: the two plan-gate lines sum to $PG_WORDS words, outside 1..$PG_MAX_WORDS — cut prose, never raise the ceiling"
fi

# ---------------------------------------------------------------------------
scenario "B5: CONTROL — the plan gate never reaches the pr-eval dispatch contract"

inc
if grep -qF -- 'plan-gate' <<<"$PREVAL"; then
  fail_msg "B5: the PR-eval dispatch prompt contract region names 'plan-gate' — #1429 must not reach pr-eval"
else
  pass_msg "B5: the PR-eval dispatch prompt contract region does not name 'plan-gate'"
fi

# ---------------------------------------------------------------------------
# C-series — #1435 `GATE=annotate`. Its own sentinel and its own 100-word
# budget: the two #1429 lines already consume 116 of their 120-word B4 ceiling,
# so widening them is not available. B1 also pins #1429 at exactly 2 lines.
# ---------------------------------------------------------------------------
PGA_SENTINEL='**Plan gate — annotate (#1435):**'
PGA_MAX_WORDS=100

PGA_LINES=()
while IFS= read -r n; do
  [ -n "$n" ] && PGA_LINES+=("$n")
done < <(grep -nF -- "$PGA_SENTINEL" "$FULLSEND" | cut -d: -f1)

G1="${PGA_LINES[0]-}"
G2="${PGA_LINES[1]-}"
G1_TEXT=""
G2_TEXT=""
[ -n "$G1" ] && G1_TEXT="$(sed -n "${G1}p" "$FULLSEND")"
[ -n "$G2" ] && G2_TEXT="$(sed -n "${G2}p" "$FULLSEND")"

scenario "C1: the annotate sentinel appears on exactly two lines"

PGA_COUNT="$(grep -cF -- "$PGA_SENTINEL" "$FULLSEND")"
inc
if [ "$PGA_COUNT" -eq 2 ]; then
  pass_msg "C1: exactly 2 lines carry '$PGA_SENTINEL'"
else
  fail_msg "C1: expected exactly 2 lines carrying '$PGA_SENTINEL', found $PGA_COUNT"
fi

# ---------------------------------------------------------------------------
scenario "C2: the Step 2 annotate arm dispatches the evaluator exactly ONCE"

for lit in 'GATE=annotate' 'once'; do
  inc
  if [ -n "$G1_TEXT" ] && grep -qF -- "$lit" <<<"$G1_TEXT"; then
    pass_msg "C2: first annotate line names '$lit'"
  else
    fail_msg "C2: first annotate line does not name '$lit'"
  fi
done

inc
if [ -n "$G1" ] && [ -n "$STEP2_LINE" ] && [ "$G1" -gt "$STEP2_LINE" ]; then
  pass_msg "C2: first annotate line ($G1) is below '$STEP2_ANCHOR' ($STEP2_LINE)"
else
  fail_msg "C2: first annotate line (${G1:-none}) is not below '$STEP2_ANCHOR' (${STEP2_LINE:-none})"
fi

inc
if [ -n "$G1" ] && [ -n "$STEP3_LINE" ] && [ "$G1" -lt "$STEP3_LINE" ]; then
  pass_msg "C2: first annotate line ($G1) is above '$STEP3_ANCHOR' ($STEP3_LINE)"
else
  fail_msg "C2: first annotate line (${G1:-none}) is not above '$STEP3_ANCHOR' (${STEP3_LINE:-none})"
fi

# ---------------------------------------------------------------------------
scenario "C3: the Step 3 annotate arm deletes the re-plan round"

# Same load-bearing reason as B3: a Revise under annotate is approved HERE, so
# the `plan-pending -> plan-approved` transition must be NAMED or the issue
# silently drops out of Step 4's `plan-reviewed`-filtered execute slate. The
# `**Scope:** structural` exception is the ONE arm that still re-plans (#1317).
for lit in 'GATE=annotate' 'plan-approved' 'plan-pending' 'plan_gate=annotate' 'plan_rounds=1' '**Scope:** structural' '#1317'; do
  inc
  if [ -n "$G2_TEXT" ] && grep -qF -- "$lit" <<<"$G2_TEXT"; then
    pass_msg "C3: second annotate line names '$lit'"
  else
    fail_msg "C3: second annotate line does not name '$lit'"
  fi
done

inc
if [ -n "$G2" ] && [ -n "$STEP3_LINE" ] && [ "$G2" -gt "$STEP3_LINE" ]; then
  pass_msg "C3: second annotate line ($G2) is below '$STEP3_ANCHOR' ($STEP3_LINE)"
else
  fail_msg "C3: second annotate line (${G2:-none}) is not below '$STEP3_ANCHOR' (${STEP3_LINE:-none})"
fi

inc
if [ -n "$G2" ] && [ -n "$STEP4_LINE" ] && [ "$G2" -lt "$STEP4_LINE" ]; then
  pass_msg "C3: second annotate line ($G2) is above '$STEP4_ANCHOR' ($STEP4_LINE)"
else
  fail_msg "C3: second annotate line (${G2:-none}) is not above '$STEP4_ANCHOR' (${STEP4_LINE:-none})"
fi

# ---------------------------------------------------------------------------
scenario "C4: prose budget — the two annotate directives sum to <= $PGA_MAX_WORDS words"

GW1="$(wc -w <<<"$G1_TEXT" | tr -d ' ')"
GW2="$(wc -w <<<"$G2_TEXT" | tr -d ' ')"
PGA_WORDS=$((GW1 + GW2))

inc
if [ "$PGA_WORDS" -ge 1 ] && [ "$PGA_WORDS" -le "$PGA_MAX_WORDS" ]; then
  pass_msg "C4: the two annotate lines sum to $PGA_WORDS words (1..$PGA_MAX_WORDS)"
else
  fail_msg "C4: the two annotate lines sum to $PGA_WORDS words, outside 1..$PGA_MAX_WORDS — cut prose, never raise the ceiling"
fi

# ---------------------------------------------------------------------------
scenario "C5: CONTROLS — #1429, the B4 budget, the log grammar and pr-eval are untouched"

inc
if [ "$PG_COUNT" -eq 2 ]; then
  pass_msg "C5: the #1429 sentinel is STILL on exactly 2 lines (annotate did not widen it)"
else
  fail_msg "C5: the #1429 sentinel is on $PG_COUNT lines — annotate must not touch it"
fi

inc
if [ "$PG_WORDS" -ge 1 ] && [ "$PG_WORDS" -le "$PG_MAX_WORDS" ]; then
  pass_msg "C5: the #1429 B4 budget still holds ($PG_WORDS <= $PG_MAX_WORDS)"
else
  fail_msg "C5: the #1429 B4 budget broke ($PG_WORDS words, cap $PG_MAX_WORDS)"
fi

inc
if grep -qF -- "$GRAMMAR" "$FULLSEND"; then
  pass_msg "C5: the TRUST-PROFILE log grammar literal is UNCHANGED (plan_gate carries the resolved value)"
else
  fail_msg "C5: the TRUST-PROFILE log grammar literal changed — the issue mandates 'log-line grammar unchanged'"
fi

for banned in "$PGA_SENTINEL" 'GATE=annotate'; do
  inc
  if grep -qF -- "$banned" <<<"$PREVAL"; then
    fail_msg "C5: the PR-eval dispatch prompt contract region names '$banned' — #1435 must not reach pr-eval"
  else
    pass_msg "C5: the PR-eval dispatch prompt contract region does not name '$banned'"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
