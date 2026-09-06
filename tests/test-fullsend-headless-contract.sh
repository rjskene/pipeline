#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-headless-contract.sh — issue #1286.
#
# In calibration run #2 the headless (`claude -p`) fullsend orchestrator merged
# wave 1 and then ENDED ITS TURN on a question ("your call on auto-merge vs
# `--manual-merge` for the rest of the run"). Under `-p` nobody can answer, so a
# question is a SILENT ABORT: 2 of 5 slate issues never executed.
#
# The fix is a `## Headless contract` section in `skills/fullsend/SKILL.md`:
# when the knob is true, fullsend and every stage it dispatches MUST NOT end a
# turn on a question — at each operator-decision point it applies the documented
# default, emits one run-log line
#
#     HEADLESS-DEFAULT: <site> decision=<what> reason=<why>
#
# and continues. Four decision sites are enumerated (a CLOSED vocabulary, so the
# assertions below can pin them exactly):
#
#   merge-policy        — Step 9's "Wait for explicit user confirmation before
#                         any non-greenlight merge" (the actual turn-ender).
#   unread-config-knob  — a config key with no read site anywhere in the tree.
#   stall-triage        — Step 6's four-option `agent-stalled` prompt, re-used
#                         by Step 7's wake loop.
#   ci-red-budget       — Step 6b's `red-retry` "Interactive mode: propose ..."
#                         branch and the `red-budget-exhausted` row.
#
# This file is the ONLY thing pinning fullsend's prose size for this change:
# there is no `tests/test-fullsend-*budget*`, `tests/test-evolve-skill-budget.sh`
# is scoped to `skills/evolve/SKILL.md`, and `tests/test-artifact-terseness-
# directives.sh` does not cover fullsend. So A6 (section body 1..200 words),
# A6b (each dispatch sentence 1..25 words) and A6c (sum <= 250) together enforce
# the issue's "<= 250 words added to skills/fullsend/SKILL.md" budget. If the
# prose overruns, CUT THE PROSE — never raise a ceiling here.
#
# Non-vacuity discipline: every ceiling is paired with a `1 <=` floor, because
# `wc -w` of a missing/empty extract is 0, which satisfies any ceiling and turns
# the assertion into a silent vacuous pass. A5 additionally opens with a
# markers-moved tripwire (both dispatch regions must extract non-empty) so a
# moved marker cannot masquerade as a missing directive — the same shape as H9
# in tests/test-no-hypothesised-writer-clause.sh.
#
# HARD BAN inherited from the plan: `PIPELINE_HEADLESS` is the ONLY new
# `PIPELINE_*` token this change may name anywhere. `scripts/`, `skills/`,
# `hooks/`, `tests/` and `docs/` are all scan dirs for
# `scripts/check-config-drift.sh`, whose referenced-set pattern is
# `\bPIPELINE_[A-Z0-9_]+\b` — a bare prose mention counts as a reference. A8
# asserts the lint's EXIT CODE, which is the mechanical enforcement of that ban.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FULLSEND="$ROOT/skills/fullsend/SKILL.md"
CONFIG_EXAMPLE="$ROOT/pipeline.config.example"
OPS_NOTES="$ROOT/docs/operational-notes.md"
DRIFT_LINT="$ROOT/scripts/check-config-drift.sh"

KNOB="PIPELINE_HEADLESS"
SECTION_HEADING="## Headless contract"
LOG_PREFIX="HEADLESS-DEFAULT:"
GRAMMAR_TEMPLATE="HEADLESS-DEFAULT: <site> decision=<what> reason=<why>"
GRAMMAR_RE="HEADLESS-DEFAULT: [a-z0-9-]+ decision=[^[:space:]]+ reason="
SENTINEL='**Headless:**'
SITES=(merge-policy unread-config-knob stall-triage ci-red-budget)

SECTION_MAX_WORDS=200
SENTENCE_MAX_WORDS=25
TOTAL_MAX_WORDS=250

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

echo "fullsend headless contract (#1286)"

for f in "$FULLSEND" "$CONFIG_EXAMPLE" "$OPS_NOTES" "$DRIFT_LINT"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Region extractors.
# ---------------------------------------------------------------------------

# The `## Headless contract` section BODY (heading line excluded), up to the
# next `^## ` heading. Parameterised by file so A10 can re-run the same
# predicates against a section-stripped copy.
section_body() {
  awk -v heading="$SECTION_HEADING" '
    $0 == heading { inblock = 1; next }
    inblock && /^## / { inblock = 0 }
    inblock { print }
  ' "$1"
}

# The inline EXECUTE dispatch prompt contract paragraph. Copied VERBATIM from
# tests/test-execute-dispatch-prompt-hardening.sh / test-no-hypothesised-writer-
# clause.sh / test-dispatch-no-background-test-run.sh / test-split-role-green-
# full-suite-pre-pr.sh so all five guards agree on the region boundary: the
# paragraph terminates on the next `   **` sub-heading. This boundary is exactly
# why the headless directive must be appended to the END of the SAME physical
# line — a new line beginning `   **Headless:**` would TERMINATE the region
# instead of joining it, silently emptying four existing guards.
exec_contract_region() {
  awk '
    /\*\*Inline execute dispatch prompt contract \(mandatory\)\.\*\*/ { inblock = 1; print; next }
    inblock && /^   \*\*/ { inblock = 0 }
    inblock { print }
  ' "$1"
}

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

# The appended headless directive: from the `**Headless:**` sentinel to end of
# line. The sentinel exists precisely so this extraction is unambiguous on a
# line that already carries several other bolded directives.
headless_sentence() {
  grep -o '\*\*Headless:\*\*.*' | sed -n '1p'
}

# The `docs/operational-notes.md` section whose BODY names the knob.
docs_headless_section() {
  awk -v knob="$KNOB" '
    /^## / {
      if (hit) { printf "%s", buf; exit }
      buf = ""; insec = 1; next
    }
    insec {
      buf = buf $0 "\n"
      if (index($0, knob) > 0) { hit = 1 }
    }
    END { if (hit) printf "%s", buf }
  ' "$1"
}

SECTION="$(section_body "$FULLSEND")"
EXEC_REGION="$(exec_contract_region "$FULLSEND")"
PREVAL_REGION="$(preval_contract_region "$FULLSEND")"

# ---------------------------------------------------------------------------
# A1 — the section exists.
# ---------------------------------------------------------------------------
scenario "A1: skills/fullsend/SKILL.md declares the '## Headless contract' section"

inc
if [ "$(grep -cxF "$SECTION_HEADING" "$FULLSEND")" -ge 1 ]; then
  pass_msg "A1: '$SECTION_HEADING' heading present"
else
  fail_msg "A1: '$SECTION_HEADING' heading ABSENT — headless runs have no default-and-continue contract"
fi

# ---------------------------------------------------------------------------
# A2 — the knob is named in the section body.
# ---------------------------------------------------------------------------
scenario "A2: the section names the $KNOB knob"

inc
if grep -qF -- "$KNOB" <<<"$SECTION"; then
  pass_msg "A2: section body names $KNOB"
else
  fail_msg "A2: section body does NOT name $KNOB — the contract has no trigger"
fi

# ---------------------------------------------------------------------------
# A3 — all four decision sites are enumerated, each with a default.
# ---------------------------------------------------------------------------
scenario "A3: four enumerated decision sites, each naming a default"

for site in "${SITES[@]}"; do
  inc
  if grep -qF -- "$site" <<<"$SECTION"; then
    pass_msg "A3: site '$site' enumerated in the section"
  else
    fail_msg "A3: site '$site' NOT enumerated — that decision point can still end a headless turn on a question"
  fi

  inc
  if grep -F -- "$site" <<<"$SECTION" | grep -qF 'decision='; then
    pass_msg "A3: site '$site' names a decision= default on its own line"
  else
    fail_msg "A3: site '$site' has no 'decision=' on its line — enumerated without a default is not a contract"
  fi
done

# ---------------------------------------------------------------------------
# A4 — the run-log grammar is pinned, and every concrete line obeys it.
# ---------------------------------------------------------------------------
scenario "A4: '$LOG_PREFIX' grammar template pinned and obeyed"

inc
if grep -qF -- "$GRAMMAR_TEMPLATE" <<<"$SECTION"; then
  pass_msg "A4: grammar template present verbatim ('$GRAMMAR_TEMPLATE')"
else
  fail_msg "A4: grammar template ABSENT — the run log has no machine-greppable shape to measure the fix by"
fi

inc
NONCONFORMING="$(grep -F -- "$LOG_PREFIX" <<<"$SECTION" \
  | grep -vF -- "$GRAMMAR_TEMPLATE" \
  | grep -vE -- "$GRAMMAR_RE" || true)"
if [ -z "$NONCONFORMING" ]; then
  pass_msg "A4: every non-template '$LOG_PREFIX' line matches '<site> decision=<what> reason=<why>' on ONE line"
else
  fail_msg "A4: non-conforming '$LOG_PREFIX' line(s): $(tr '\n' '|' <<<"$NONCONFORMING")"
fi

# ---------------------------------------------------------------------------
# A5 — the directive is carried by BOTH inline dispatch prompt contracts.
#      A dispatched general-purpose/tdd-implementer subagent never loads a
#      SKILL.md body, so the dispatch-site prompt is the binding contract.
# ---------------------------------------------------------------------------
scenario "A5: both inline dispatch prompt contracts carry the headless directive"

# A5.0 — markers-moved tripwire. Runs FIRST: an empty region would make every
# assertion below report a missing directive when the real fault is a moved
# marker (mirrors H9 in tests/test-no-hypothesised-writer-clause.sh).
inc
if [ -n "$EXEC_REGION" ] && [ -n "$PREVAL_REGION" ]; then
  pass_msg "A5.0 tripwire: both contract regions extracted non-empty (exec=$(wc -l <<<"$EXEC_REGION") lines, pr-eval=$(wc -l <<<"$PREVAL_REGION") lines)"
else
  fail_msg "A5.0 tripwire: a contract region extracted EMPTY — the bold marker moved; fix the extractor, not the skill"
fi

for needle in "$SENTINEL" "$KNOB" "$LOG_PREFIX"; do
  inc
  if grep -qF -- "$needle" <<<"$EXEC_REGION"; then
    pass_msg "A5: execute contract paragraph carries '$needle'"
  else
    fail_msg "A5: execute contract paragraph does NOT carry '$needle' — execute subagents do not inherit the contract"
  fi

  inc
  if grep -qF -- "$needle" <<<"$PREVAL_REGION"; then
    pass_msg "A5: PR-eval contract paragraph carries '$needle'"
  else
    fail_msg "A5: PR-eval contract paragraph does NOT carry '$needle' — evaluator subagents do not inherit the contract"
  fi
done

# ---------------------------------------------------------------------------
# A6 / A6b / A6c — the prose budget (the issue's <= 250 added words).
# ---------------------------------------------------------------------------
scenario "A6: section body word budget (1..$SECTION_MAX_WORDS)"

SECTION_WORDS="$(wc -w <<<"$SECTION" | tr -d ' ')"
EXEC_SENTENCE="$(headless_sentence <<<"$EXEC_REGION")"
PREVAL_SENTENCE="$(headless_sentence <<<"$PREVAL_REGION")"
EXEC_SENTENCE_WORDS="$(wc -w <<<"$EXEC_SENTENCE" | tr -d ' ')"
PREVAL_SENTENCE_WORDS="$(wc -w <<<"$PREVAL_SENTENCE" | tr -d ' ')"
TOTAL_WORDS=$((SECTION_WORDS + EXEC_SENTENCE_WORDS + PREVAL_SENTENCE_WORDS))

echo "headless prose: section=$SECTION_WORDS exec_sentence=$EXEC_SENTENCE_WORDS preval_sentence=$PREVAL_SENTENCE_WORDS total=$TOTAL_WORDS"

inc
if [ "$SECTION_WORDS" -le "$SECTION_MAX_WORDS" ]; then
  pass_msg "A6: section body within budget (words=$SECTION_WORDS <= $SECTION_MAX_WORDS)"
else
  fail_msg "A6: section body EXCEEDS budget (words=$SECTION_WORDS > $SECTION_MAX_WORDS) — cut prose, never raise the ceiling"
fi

inc
if [ "$SECTION_WORDS" -ge 1 ]; then
  pass_msg "A6: section body is non-vacuous (words=$SECTION_WORDS >= 1)"
else
  fail_msg "A6: section body is EMPTY (words=$SECTION_WORDS) — a missing section must not pass the ceiling at 0"
fi

scenario "A6b: per-dispatch-sentence word budget (1..$SENTENCE_MAX_WORDS each)"

inc
if [ "$EXEC_SENTENCE_WORDS" -le "$SENTENCE_MAX_WORDS" ]; then
  pass_msg "A6b: execute dispatch sentence within budget (words=$EXEC_SENTENCE_WORDS <= $SENTENCE_MAX_WORDS)"
else
  fail_msg "A6b: execute dispatch sentence EXCEEDS budget (words=$EXEC_SENTENCE_WORDS > $SENTENCE_MAX_WORDS)"
fi

inc
if [ "$EXEC_SENTENCE_WORDS" -ge 1 ]; then
  pass_msg "A6b: execute dispatch sentence is non-vacuous (words=$EXEC_SENTENCE_WORDS >= 1)"
else
  fail_msg "A6b: no '$SENTINEL' sentence on the execute contract line (words=0) — an absent sentence must not pass the ceiling"
fi

inc
if [ "$PREVAL_SENTENCE_WORDS" -le "$SENTENCE_MAX_WORDS" ]; then
  pass_msg "A6b: PR-eval dispatch sentence within budget (words=$PREVAL_SENTENCE_WORDS <= $SENTENCE_MAX_WORDS)"
else
  fail_msg "A6b: PR-eval dispatch sentence EXCEEDS budget (words=$PREVAL_SENTENCE_WORDS > $SENTENCE_MAX_WORDS)"
fi

inc
if [ "$PREVAL_SENTENCE_WORDS" -ge 1 ]; then
  pass_msg "A6b: PR-eval dispatch sentence is non-vacuous (words=$PREVAL_SENTENCE_WORDS >= 1)"
else
  fail_msg "A6b: no '$SENTINEL' sentence on the PR-eval contract line (words=0) — an absent sentence must not pass the ceiling"
fi

scenario "A6c: total added prose <= $TOTAL_MAX_WORDS words"

inc
if [ "$TOTAL_WORDS" -le "$TOTAL_MAX_WORDS" ]; then
  pass_msg "A6c: total added prose within the issue budget ($SECTION_WORDS + $EXEC_SENTENCE_WORDS + $PREVAL_SENTENCE_WORDS = $TOTAL_WORDS <= $TOTAL_MAX_WORDS)"
else
  fail_msg "A6c: total added prose EXCEEDS the issue budget ($SECTION_WORDS + $EXEC_SENTENCE_WORDS + $PREVAL_SENTENCE_WORDS = $TOTAL_WORDS > $TOTAL_MAX_WORDS) — cut prose, never raise the ceiling"
fi

# ---------------------------------------------------------------------------
# A7 — the knob is declared COMMENTED in pipeline.config.example.
#      Commented still counts as DECLARED for check-config-drift.sh (its
#      declared-set pattern is `^\s*#?\s*PIPELINE_[A-Z0-9_]+=`), and commented
#      is what keeps tests/test-doctor-golden-seed-set.sh green — `doctor
#      --fix config` skips commented knobs, so the seeded set still equals
#      GOLDEN verbatim (defaults-in-code, #1052).
# ---------------------------------------------------------------------------
scenario "A7: $KNOB declared COMMENTED in pipeline.config.example"

inc
if grep -qE "^[[:space:]]*#[[:space:]]*${KNOB}=" "$CONFIG_EXAMPLE"; then
  pass_msg "A7: $KNOB declared (commented) in pipeline.config.example"
else
  fail_msg "A7: $KNOB NOT declared in pipeline.config.example — operators have no documented knob and the drift lint sees it as UNDOCUMENTED"
fi

inc
if grep -qE "^[[:space:]]*${KNOB}=" "$CONFIG_EXAMPLE"; then
  fail_msg "A7: $KNOB is declared UNCOMMENTED — a seeded knob pins its value and defeats defaults-in-code (#1052)"
else
  pass_msg "A7: $KNOB is not declared uncommented (defaults-in-code preserved)"
fi

# ---------------------------------------------------------------------------
# A8 — the change is config-drift neutral, asserted BY EXIT CODE.
#      This is the mechanical enforcement of the "no new undeclared PIPELINE_*
#      literal anywhere in this change's prose" ban: skills/, docs/ and tests/
#      are all scan dirs, so a bare prose mention counts as a reference.
# ---------------------------------------------------------------------------
scenario "A8: scripts/check-config-drift.sh is drift-neutral (exit 0)"

DRIFT_OUT="$(bash "$DRIFT_LINT" 2>&1)"
DRIFT_RC=$?

inc
if [ "$DRIFT_RC" -eq 0 ]; then
  pass_msg "A8: check-config-drift.sh exits 0"
else
  fail_msg "A8: check-config-drift.sh exits $DRIFT_RC — $(tr '\n' '|' <<<"$DRIFT_OUT")"
fi

inc
if grep -qF -- "$KNOB" <<<"$DRIFT_OUT"; then
  fail_msg "A8: $KNOB reported by the drift lint (ORPHAN or UNDOCUMENTED) — declare it commented in pipeline.config.example"
else
  pass_msg "A8: $KNOB is not reported as ORPHAN or UNDOCUMENTED"
fi

# ---------------------------------------------------------------------------
# A9 — the operator-facing docs paragraph.
# ---------------------------------------------------------------------------
scenario "A9: docs/operational-notes.md documents headless mode"

inc
if grep -qF -- "$KNOB" "$OPS_NOTES"; then
  pass_msg "A9: docs/operational-notes.md names $KNOB"
else
  fail_msg "A9: docs/operational-notes.md does NOT name $KNOB — headless mode is undocumented for operators"
fi

DOCS_SECTION="$(docs_headless_section "$OPS_NOTES")"
inc
if grep -qE '\.md#[A-Za-z0-9_-]+' <<<"$DOCS_SECTION"; then
  fail_msg "A9: the headless docs section uses an anchored cross-reference (\`.md#...\`) — file-level links only"
else
  pass_msg "A9: the headless docs section uses file-level links only (no \`.md#anchor\`)"
fi

# ---------------------------------------------------------------------------
# A10 — negative control. Strip the section from a throwaway copy and re-run
#       the A1/A3/A4 predicates against it: they MUST fail there. Guards
#       against a predicate that any file satisfies.
# ---------------------------------------------------------------------------
scenario "A10: negative control — predicates fail on a section-stripped copy"

NEG_DIR="$(mktemp -d)"
trap 'rm -rf "$NEG_DIR"' EXIT
NEG_COPY="$NEG_DIR/SKILL.md"

awk -v heading="$SECTION_HEADING" '
  $0 == heading { strip = 1; next }
  strip && /^## / { strip = 0 }
  strip { next }
  { print }
' "$FULLSEND" > "$NEG_COPY"

NEG_SECTION="$(section_body "$NEG_COPY")"

inc
if [ "$(grep -cxF "$SECTION_HEADING" "$NEG_COPY")" -eq 0 ]; then
  pass_msg "A10: A1 predicate FAILS on the section-stripped copy (as it must)"
else
  fail_msg "A10: A1 predicate still passes on the section-stripped copy — the predicate is satisfied by unrelated prose"
fi

NEG_SITES_FOUND=0
for site in "${SITES[@]}"; do
  grep -qF -- "$site" <<<"$NEG_SECTION" && NEG_SITES_FOUND=$((NEG_SITES_FOUND + 1))
done
inc
if [ "$NEG_SITES_FOUND" -eq 0 ]; then
  pass_msg "A10: A3 predicate FAILS on the section-stripped copy (0/${#SITES[@]} sites found)"
else
  fail_msg "A10: A3 predicate still finds $NEG_SITES_FOUND/${#SITES[@]} sites on the section-stripped copy — it is reading prose outside the section"
fi

inc
if grep -qF -- "$GRAMMAR_TEMPLATE" <<<"$NEG_SECTION"; then
  fail_msg "A10: A4 predicate still finds the grammar template on the section-stripped copy — it is reading prose outside the section"
else
  pass_msg "A10: A4 predicate FAILS on the section-stripped copy (as it must)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
