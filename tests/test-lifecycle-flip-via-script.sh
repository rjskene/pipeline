#!/bin/bash
set -uo pipefail
#
# tests/test-lifecycle-flip-via-script.sh — issue #1449.
#
# Two guard families over the same change:
#
#   L1-L5 — every PLAN-lifecycle label flip in a skill HOT PATH goes through
#           `scripts/transition-issue.sh`, not a raw `gh issue edit
#           --add-label`. The auto-mode classifier denied the raw form four
#           times in calibration run 19 (`[CI Bypass]`) while every
#           `scripts/*.sh` call passed, and a classifier denial is TERMINAL in
#           that mode — the orchestrator ended its turn asking the operator.
#
#   H1-H5 — a Bash result containing `denied by the Claude Code auto mode
#           classifier` is a named `permission-denied` arm of
#           `skills/fullsend/SKILL.md`'s `## Headless contract`: retry once,
#           then skip the step. And `HEADLESS-DEFAULT:` lines are written in
#           the turn's TEXT, never via `echo` — the escape-hatch `echo` was
#           itself denied (`[Auto-Mode Bypass]`) in run 19.
#
# TRIPWIRE SCOPE IS A POSITIVE CHOICE: `plan-approved` + `plan-reviewed` only,
# `skills/*/SKILL.md` only. `skills/execute-issue-plan/SKILL.md`'s
# `in-progress`/`pr-open` flips and `skills/classify-issue/SKILL.md`'s path-label
# flips are out of this issue's scope. `skills/*/references/*.md` and `scripts/`
# are EXEMPT by design — `references/auto-merge-gate.md`'s `--add-label
# "manual-merge"` and `scripts/post-plan.sh`'s `plan-pending` add are legitimate.
#
# NO NEW SITE TOKEN. `tests/test-fullsend-headless-contract.sh` pins a CLOSED
# six-site vocabulary that `docs/operational-notes.md` must mirror (A9b), so
# classifier-deny is folded into the EXISTING `permission-denied` site.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FULLSEND="$ROOT/skills/fullsend/SKILL.md"
EVAL_PLAN="$ROOT/skills/evaluate-issue-plan/SKILL.md"
HELPER_NAME="transition-issue.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

echo "lifecycle flips route through $HELPER_NAME (#1449)"

for f in "$FULLSEND" "$EVAL_PLAN"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The raw-flip scanner. Deliberately narrow: the two PLAN-lifecycle labels only.
RAW_FLIP_RE='--add-label[[:space:]=]+["'"'"']?(plan-approved|plan-reviewed)["'"'"']?'
scan_raw_flips() { grep -rnE -- "$RAW_FLIP_RE" "$@" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
scenario "L1: no skills/*/SKILL.md carries a raw plan-lifecycle --add-label flip"

inc
HITS="$(scan_raw_flips "$ROOT"/skills/*/SKILL.md)"
HIT_COUNT="$(printf '%s' "$HITS" | grep -c . || true)"
if [ "$HIT_COUNT" -eq 0 ]; then
  pass_msg "L1: zero raw plan-approved/plan-reviewed --add-label flips in any skill hot path"
else
  fail_msg "L1: $HIT_COUNT raw plan-lifecycle flip(s) remain — route them through scripts/$HELPER_NAME"
  printf '%s\n' "$HITS" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
scenario "L2: positive control — the scanner finds a planted raw flip"

inc
FIXTURE="$TMP/SKILL.md"
cat > "$FIXTURE" <<'FIX'
# fixture
Some prose that mentions transition-issue.sh.
```bash
gh issue edit 1 --add-label "plan-approved"
```
FIX
FIX_COUNT="$(scan_raw_flips "$FIXTURE" | grep -c . || true)"
if [ "$FIX_COUNT" -eq 1 ]; then
  pass_msg "L2: scanner reports exactly 1 hit on the planted fixture (L1's zero means clean, not broken)"
else
  fail_msg "L2: scanner reported $FIX_COUNT hits on the planted fixture, expected 1 — L1 is vacuous"
fi

# ---------------------------------------------------------------------------
scenario "L3: fullsend Step 4 Approve region calls the helper"

# From `4. **Approve**` to the next `### ` heading or numbered step.
approve_region() {
  awk '
    /^4\. \*\*Approve\*\*/ { inblock = 1; print; next }
    inblock && (/^### / || /^[0-9]+[a-z]?\. /) { inblock = 0 }
    inblock { print }
  ' "$1"
}
APPROVE="$(approve_region "$FULLSEND")"

inc
if [ -n "$APPROVE" ]; then
  pass_msg "L3.0 tripwire: the Step 4 Approve region extracted non-empty ($(wc -l <<<"$APPROVE") lines)"
else
  fail_msg "L3.0 tripwire: the Step 4 Approve region extracted EMPTY — the '4. **Approve**' marker moved; fix the extractor, not the skill"
fi

for lit in "$HELPER_NAME" '--to plan-approved' '--from plan-reviewed'; do
  inc
  if [ -n "$APPROVE" ] && grep -qF -- "$lit" <<<"$APPROVE"; then
    pass_msg "L3: Step 4 Approve region names '$lit'"
  else
    fail_msg "L3: Step 4 Approve region does NOT name '$lit'"
  fi
done

# ---------------------------------------------------------------------------
scenario "L4: each sentinel directive names the helper on its OWN physical line"

# The three per-line-budgeted directives guarded by tests/test-fullsend-trust-
# profile.sh A2/B3/C3. Those assertions read ONE physical line each, so a
# directive split across lines silently EMPTIES them — hence "same line".
sentinel_line() {
  # sentinel_line <fixed-sentinel> <1-based occurrence>
  grep -nF -- "$1" "$FULLSEND" | sed -n "${2}p" | cut -d: -f2-
}

# Occurrence indices pinned so a relocation reds loudly instead of silently
# selecting a different line: in SKILL.md the Trust-profile sentinel appears
# once, each Plan-gate sentinel twice (the Step 2 read site, then the Step 3 arm).
declare -a SENT_DESC=('Trust profile (#1291) Step 2 arm' 'Plan gate (#1429) Step 3 arm' 'Plan gate — annotate (#1435) Step 3 arm')
declare -a SENT_LIT=('**Trust profile (#1291):**' '**Plan gate (#1429):**' '**Plan gate — annotate (#1435):**')
declare -a SENT_IDX=(1 2 2)
declare -a SENT_EXPECT_COUNT=(1 2 2)

for i in 0 1 2; do
  lit="${SENT_LIT[$i]}"; idx="${SENT_IDX[$i]}"; desc="${SENT_DESC[$i]}"
  want="${SENT_EXPECT_COUNT[$i]}"

  inc
  got="$(grep -cF -- "$lit" "$FULLSEND" || true)"
  if [ "$got" -eq "$want" ]; then
    pass_msg "L4.0 tripwire: '$lit' appears $got time(s) in SKILL.md (as pinned)"
  else
    fail_msg "L4.0 tripwire: '$lit' appears $got time(s) in SKILL.md, expected $want — the occurrence index below is no longer trustworthy"
  fi

  LINE="$(sentinel_line "$lit" "$idx")"
  inc
  if [ -n "$LINE" ] && grep -qF -- "$HELPER_NAME" <<<"$LINE"; then
    pass_msg "L4: the $desc names $HELPER_NAME on the SAME physical line"
  else
    fail_msg "L4: the $desc does NOT name $HELPER_NAME on its own line (split lines empty the per-line A2/B3/C3 budgets)"
  fi

  inc
  if [ -n "$LINE" ] && ! grep -qE -- "$RAW_FLIP_RE" <<<"$LINE"; then
    pass_msg "L4: the $desc carries no raw plan-lifecycle --add-label flip"
  else
    fail_msg "L4: the $desc still carries a raw plan-lifecycle --add-label flip"
  fi
done

# ---------------------------------------------------------------------------
scenario "L5: evaluate-issue-plan Step 6 Approve route calls the helper"

eval_plan_step6() {
  awk '
    /^6\. \*\*Update labels\*\*/ { inblock = 1; print; next }
    inblock && /^## / { inblock = 0 }
    inblock { print }
  ' "$1"
}
STEP6="$(eval_plan_step6 "$EVAL_PLAN")"

inc
if [ -n "$STEP6" ]; then
  pass_msg "L5.0 tripwire: the evaluate-issue-plan Step 6 region extracted non-empty ($(wc -l <<<"$STEP6") lines)"
else
  fail_msg "L5.0 tripwire: the Step 6 region extracted EMPTY — the '6. **Update labels**' marker moved; fix the extractor, not the skill"
fi

for lit in "$HELPER_NAME" '--to plan-reviewed' '--from plan-pending'; do
  inc
  if [ -n "$STEP6" ] && grep -qF -- "$lit" <<<"$STEP6"; then
    pass_msg "L5: evaluate-issue-plan Step 6 names '$lit'"
  else
    fail_msg "L5: evaluate-issue-plan Step 6 does NOT name '$lit'"
  fi
done

# ===========================================================================
# H-series — the `## Headless contract` classifier-deny arm (#1449).
# ===========================================================================

SECTION_HEADING='## Headless contract'
GRAMMAR_TEMPLATE='HEADLESS-DEFAULT: <site> decision=<what> reason=<why>'
GRAMMAR_RE='HEADLESS-DEFAULT: [a-z0-9-]+ decision=[^[:space:]]+ reason='
CLASSIFIER_LIT='denied by the Claude Code auto mode classifier'

# Copied VERBATIM from tests/test-fullsend-headless-contract.sh so both guards
# agree on the section boundary.
section_body() {
  awk -v heading="$SECTION_HEADING" '
    $0 == heading { inblock = 1; next }
    inblock && /^## / { inblock = 0 }
    inblock { print }
  ' "$1"
}

# The concrete permission-denied example line inside the section.
pd_line() { grep -F -- 'HEADLESS-DEFAULT: permission-denied' <<<"$1" | sed -n '1p'; }

h1_ok() { grep -qF -- "$CLASSIFIER_LIT" <<<"$1"; }

# H2 — the classifier-deny arm names ONE identical-command retry, the
# reason token, and (plan-eval amendment 1) the issue's own `site=` / `issue=#`
# tokens, all on a line that still satisfies A4's grammar.
h2_ok() {
  local s="$1" L
  L="$(pd_line "$s")"
  [ -n "$L" ] || return 1
  grep -qF -- 'reason=classifier-deny' <<<"$L" || return 1
  grep -qE -- "$GRAMMAR_RE"            <<<"$L" || return 1
  grep -qF -- 'site='                  <<<"$L" || return 1
  grep -qF -- 'issue=#'                <<<"$L" || return 1
  grep -qF -- 'identical'              <<<"$s" || return 1
  grep -qF -- 'ONCE'                   <<<"$s" || return 1
}

# H3 — the skip is spelled out: label untouched, Flagged in Step 8's table,
# slate continues.
h3_ok() {
  local L
  L="$(pd_line "$1")"
  [ -n "$L" ] || return 1
  grep -qF -- 'label'          <<<"$L" || return 1
  grep -qF -- 'Flagged'        <<<"$L" || return 1
  grep -qF -- "Step 8's table" <<<"$L" || return 1
  grep -qF -- 'slate'          <<<"$L" || return 1
}

# H4 — the no-`echo` rule exists AND sits where A4 tolerates it.
#
# This is plan-eval amendment 1, pinned rather than merely avoided.
# tests/test-fullsend-headless-contract.sh A4 requires every section line
# carrying `HEADLESS-DEFAULT:` — except the verbatim GRAMMAR_TEMPLATE — to match
# GRAMMAR_RE. A new prose bullet quoting `HEADLESS-DEFAULT:` to say "never via
# echo" therefore REDS A4 (demonstrated by the plan evaluation's control). The
# rule must live on the grammar-template INTRO line, which A4 filters out.
h4_ok() {
  local s="$1" ECHO_LINES NONCONF l
  ECHO_LINES="$(grep -F -- 'echo' <<<"$s" || true)"
  [ -n "$ECHO_LINES" ] || return 1
  grep -qE -- '(never|NEVER|not)' <<<"$ECHO_LINES" || return 1
  # Every `echo` line that also names HEADLESS-DEFAULT must BE the template line.
  while IFS= read -r l; do
    case "$l" in
      *HEADLESS-DEFAULT:*) grep -qF -- "$GRAMMAR_TEMPLATE" <<<"$l" || return 1 ;;
    esac
  done <<<"$ECHO_LINES"
  # A4's own invariant, re-asserted here so the hazard is pinned in THIS file.
  NONCONF="$(grep -F -- 'HEADLESS-DEFAULT:' <<<"$s" \
    | grep -vF -- "$GRAMMAR_TEMPLATE" \
    | grep -vE -- "$GRAMMAR_RE" || true)"
  [ -z "$NONCONF" ]
}

SECTION="$(section_body "$FULLSEND")"

scenario "H1-H4: the headless contract names the classifier-deny arm"

declare -a H_FN=(h1_ok h2_ok h3_ok h4_ok)
declare -a H_DESC=(
  "H1: the section names the literal '$CLASSIFIER_LIT'"
  "H2: the classifier-deny line names reason=classifier-deny, site=, issue=# and ONE identical retry, and obeys A4's grammar"
  "H3: the classifier-deny line states the label is untouched, the issue is Flagged in Step 8's table, and the slate continues"
  "H4: a never/not clause forbids \`echo\` for HEADLESS-DEFAULT: lines, and no non-template HEADLESS-DEFAULT: line breaks A4's grammar"
)

for i in 0 1 2 3; do
  inc
  if "${H_FN[$i]}" "$SECTION"; then
    pass_msg "${H_DESC[$i]}"
  else
    fail_msg "${H_DESC[$i]} — NOT satisfied"
  fi
done

# ---------------------------------------------------------------------------
scenario "H5: negative control — H1-H4 all FAIL on a section-stripped copy"

NEG="$TMP/fullsend-stripped.md"
awk -v heading="$SECTION_HEADING" '
  $0 == heading { strip = 1; next }
  strip && /^## / { strip = 0 }
  strip { next }
  { print }
' "$FULLSEND" > "$NEG"
NEG_SECTION="$(section_body "$NEG")"

inc
if [ -z "$NEG_SECTION" ]; then
  pass_msg "H5.0 tripwire: the stripped copy yields an EMPTY headless section"
else
  fail_msg "H5.0 tripwire: the stripped copy still yields a non-empty headless section — the stripper is broken"
fi

for i in 0 1 2 3; do
  inc
  if "${H_FN[$i]}" "$NEG_SECTION"; then
    fail_msg "H5: predicate ${H_FN[$i]} still passes on the section-stripped copy — it is reading prose OUTSIDE the section"
  else
    pass_msg "H5: predicate ${H_FN[$i]} FAILS on the section-stripped copy (as it must)"
  fi
done

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
