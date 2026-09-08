#!/usr/bin/env bash
# Body-scoped prose guard for issue #1224: the RED/GREEN ledger contract.
#
# TWO COUPLED HALVES, ONE GUARD:
#   1. `skills/plan-issue/SKILL.md` must REQUIRE a per-file/per-task
#      `**RED/GREEN ledger:**` TABLE (not a prose sentence) in the canonical
#      plan template, plus the contract subsection that explains it.
#   2. `skills/evaluate-issue-plan/SKILL.md` must require the evaluator to
#      EXECUTE the predicted RED rather than reason about it, to report
#      unrunnable rows verbatim, to Revise on a missing/prose-only ledger, and
#      to treat divergence as BLOCKING — plus the report-template row.
#
# ENGINEERED PROPERTIES (each is itself asserted, not assumed):
#
#   * BODY-SCOPED. Every presence assertion runs against `skill_body`, never
#     the whole file — a YAML frontmatter `description:` must never satisfy a
#     body clause guard (the #1218 lesson; see tests/_lib/skill-body.sh).
#
#   * NO PIPES, except the Case F awk-extraction plumbing. `skill_body | grep -q`
#     SIGPIPEs the upstream awk and returns 141 under `set -o pipefail`, so a
#     PRESENT anchor reports ABSENT. That flake makes negative controls pass
#     vacuously. Everything else here uses `skill_body_has`, here-strings, or
#     redirections.
#
#   * NO `set -e`. Every case runs so the FULL failure inventory lands in one
#     pass — the RED author and the GREEN implementer both diff their observed
#     output against the plan's ledger, which is impossible if the suite aborts
#     on the first failure.
#
#   * SINGLE RED SIGNAL. ONLY Case A emits the string
#     `missing ledger anchor in body of`, and it prints a FIXED repo-relative
#     label rather than `$SKILL_PI` / `$SKILL_EP`, so mutant copies under $TMP
#     cannot perturb the expected output. Inner-mode output is captured to a
#     file, never stdout. That is what makes the RED-line count exact:
#       10 at the [split-role-red] commit, 5 after the plan-issue insertions,
#       0 once evaluate-issue-plan is done.
#
#   * CONTROLS NAME THEIR ANCHOR. No control is satisfied by "exit non-zero" —
#     an infrastructure error would satisfy that. Case C proves each deletion
#     removes THAT anchor and no other (count-for-count); Case G proves a
#     byte-identical no-op is NOT reported caught.
#
# ASSERTION-GRANULARITY NOTE (#1224 ledger comparison): the approved plan's
# ledger reports `PASS=`/`FAIL=` counters observed from a prototype. The FAIL
# counters and the RED-line counts are the load-bearing predictions; the PASS
# counters depend on how many control assertions are itemised and are expected
# to be HIGHER here (Case C runs its (ii)/(iii) legs unconditionally rather than
# short-circuiting on a failed precondition, and Cases D/E/F/G each itemise a
# non-vacuity control). Report divergence; do not bend the test to match.
#
# Env overrides (used by the Case C/D/E/G/H machinery, which builds mutants and
# re-invokes this file in inner mode):
#   SKILL_PI  path to plan-issue/SKILL.md
#   SKILL_EP  path to evaluate-issue-plan/SKILL.md
#   SKILL_PR  path to evaluate-issue-pr/SKILL.md   (Case F awk source)
#   LEDGER_INNER=1        inner mode: Case A ONLY, never recurses
#   LEDGER_NOOP_REPS      Case G repetitions (default 10)
#   LEDGER_SKIP_CASE_H=1  skip Case H's own recursive full-suite dispatch —
#                         set by Case H itself on the child invocation it
#                         spawns, so the fence-rename mutant (which already
#                         lacks a ```markdown fence) does not recurse forever
#                         trying to rename a fence that is no longer there.
#
# #1232 (Case H / Case I, below): unbalanced literal backticks inside a
# double-quoted pass_msg/fail_msg string are parsed as command substitution,
# which can swallow an entire `else` branch at PARSE time — the branch's
# fail_msg call is never invoked, `inc` still runs, and PASS+FAIL silently
# under-reports relative to TESTS. Case H is the fence-rename regression for
# the specific D(0) defect; Case I is the general self-accounting invariant
# (PASS + FAIL == TESTS) that generalises to any other dead branch of this
# shape.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "$0")"
HELPER_LIB="$SCRIPT_DIR/_lib/skill-body.sh"

if [ ! -f "$HELPER_LIB" ]; then
  echo "ERROR: helper library not found at $HELPER_LIB" >&2
  exit 1
fi
# shellcheck source=_lib/skill-body.sh
source "$HELPER_LIB"

SKILL_PI="${SKILL_PI:-$SCRIPT_DIR/../skills/plan-issue/SKILL.md}"
SKILL_EP="${SKILL_EP:-$SCRIPT_DIR/../skills/evaluate-issue-plan/SKILL.md}"
SKILL_PR="${SKILL_PR:-$SCRIPT_DIR/../skills/evaluate-issue-pr/SKILL.md}"

INNER="${LEDGER_INNER:-0}"
NOOP_REPS="${LEDGER_NOOP_REPS:-10}"
SKIP_CASE_H="${LEDGER_SKIP_CASE_H:-0}"

# FIXED labels for the Case A failure line. Deliberately NOT "$SKILL_PI" — the
# mutation machinery points that variable at copies under $TMP, and a $TMP path
# in the RED line would make the expected output unstable across runs.
LABEL_PI='skills/plan-issue/SKILL.md'
LABEL_EP='skills/evaluate-issue-plan/SKILL.md'

# The one and only RED signal string of this suite.
RED_SIGNAL='missing ledger anchor in body of'

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$SKILL_PI" "$SKILL_EP"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: SKILL.md not found at $f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Anchor set — verbatim literals. RED and GREEN must agree byte-for-byte.
# ---------------------------------------------------------------------------
# PRESENCE-ONLY anchor: the template row header. Legitimately occurs TWICE in
# the finished body (once in the canonical ```markdown template, once as a
# backticked reference in the contract subsection), so it is EXEMPT from the
# Case B uniqueness rule and is not a Case C deletion target.
PI_SECTION='**RED/GREEN ledger:**'

# UNIQUE anchors — exactly one body line each, and no two on the same line.
PI_UNIQUE=(
  '| test file | red at RED commit | vacuously green until | fully green at |'
  'you MUST state WHY it is green'
  'redness depends on state a LATER task creates'
  'a PREDICTION to verify, not a script to satisfy'
)

EP_UNIQUE=(
  '**RED/GREEN ledger execution (#1224):**'
  '**Missing or prose-only ledger → Revise:**'
  '**Divergence is BLOCKING:**'
  '**RED/GREEN ledger verified:**'
  'red-not-reproduced:'
)

# The EIGHT #1224-adjacent anchors owned by #1218. Case E is the non-collision
# regression: new evaluate-issue-plan prose must not contain any of these as a
# SUBSTRING, or tests/test-evaluator-executable-verification-prose.sh Case B
# (exactly-once per body) breaks.
A1218=(
  'not-executed:'
  '**Guard claims verified:**'
  '**Trigger (mechanical'
  '**Run a negative control.**'
  '**Scope at plan-eval time.**'
  '**Executable verification (#1218):**'
  '## Executable verification'
  'A guard that passes is not evidence until you have seen it fail on something.'
)

# Populates the global UNIQUE array for <label> (pi|ep).
unique_for() {
  case "$1" in
    pi) UNIQUE=("${PI_UNIQUE[@]}") ;;
    ep) UNIQUE=("${EP_UNIQUE[@]}") ;;
    *)  echo "ERROR: unknown label $1" >&2; return 1 ;;
  esac
}

skill_file() {
  case "$1" in
    pi) printf '%s' "$SKILL_PI" ;;
    ep) printf '%s' "$SKILL_EP" ;;
    *)  echo "ERROR: unknown label $1" >&2; return 1 ;;
  esac
}

skill_label() {
  case "$1" in
    pi) printf '%s' "$LABEL_PI" ;;
    ep) printf '%s' "$LABEL_EP" ;;
    *)  echo "ERROR: unknown label $1" >&2; return 1 ;;
  esac
}

LABELS=(pi ep)

# ---------------------------------------------------------------------------
# Case A — POSITIVE PRESENCE. The ONLY emitter of $RED_SIGNAL.
# 10 (file, anchor) pairs: 5 plan-issue (PI_SECTION + 4 unique), 5
# evaluate-issue-plan (5 unique).
# ---------------------------------------------------------------------------
case_a() {
  local a f lbl

  f="$(skill_file pi)"
  lbl="$(skill_label pi)"
  inc
  if skill_body_has "$f" "$PI_SECTION"; then
    pass_msg "pi: ledger anchor present in body: $PI_SECTION"
  else
    fail_msg "pi: $RED_SIGNAL $lbl: $PI_SECTION"
  fi

  local label
  for label in "${LABELS[@]}"; do
    f="$(skill_file "$label")"
    lbl="$(skill_label "$label")"
    unique_for "$label"
    for a in "${UNIQUE[@]}"; do
      inc
      if skill_body_has "$f" "$a"; then
        pass_msg "$label: ledger anchor present in body: $a"
      else
        fail_msg "$label: $RED_SIGNAL $lbl: $a"
      fi
    done
  done
}

if [ "$INNER" = "1" ]; then
  case_a
  echo ""
  echo "  INNER $TESTS cases: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pipe-free primitives. Nothing below (Case F's awk extraction excepted) may
# use a shell pipeline — `cmd | grep`, `cmd | head`, `diff | head` all SIGPIPE
# their producer and return 141 under `set -o pipefail`, the exact failure
# class this guard exists to avoid.
# ---------------------------------------------------------------------------
str_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

out_has() { case "$(<"$1")" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# Count BODY lines of <file> containing literal <needle>. Pure bash.
count_body_lines() {
  local f="$1" needle="$2" line n=0 body
  body="$(skill_body "$f")"
  while IFS= read -r line; do
    case "$line" in *"$needle"*) n=$((n + 1)) ;; esac
  done <<< "$body"
  printf '%s' "$n"
}

# Copy <src> to <dst> dropping every line containing literal <needle>.
mut_drop_lines() {
  local rc=0
  grep -vF -- "$3" "$1" > "$2" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "ERROR: grep failed (rc=$rc) building mutant $2" >&2
    return 1
  fi
  return 0
}

# Run THIS file in inner mode (Case A only) against <pi> <ep>, capturing all
# output into <outfile>. Echoes the child exit code. Output NEVER reaches this
# process's stdout — that is what keeps the RED-line count exact.
run_inner() {
  local rc=0
  LEDGER_INNER=1 SKILL_PI="$1" SKILL_EP="$2" bash "$SELF" > "$3" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# Parse the trailing "<N> cases: <P> passed, <F> failed" / "PASS=<P> FAIL=<F>"
# summary lines out of a captured full-run <outfile>. Echoes "TESTS|PASS|FAIL"
# (empty fields if the summary was never printed, e.g. the child crashed).
# Pure bash — no pipe, so it cannot itself SIGPIPE under pipefail.
parse_run_totals() {
  local outfile="$1" line rest tests_n="" pass_n="" fail_n=""
  while IFS= read -r line; do
    case "$line" in
      *' cases: '*' passed, '*' failed'*)
        rest="${line#"${line%%[![:space:]]*}"}"
        tests_n="${rest%% cases:*}"
        ;;
      *'PASS='*'FAIL='*)
        rest="${line#*PASS=}"
        pass_n="${rest%% FAIL=*}"
        fail_n="${rest##*FAIL=}"
        ;;
    esac
  done < "$outfile"
  printf '%s|%s|%s' "$tests_n" "$pass_n" "$fail_n"
}

# ---------------------------------------------------------------------------
echo "Case A: every ledger anchor is present in the BODY of both skills"
case_a

# ---------------------------------------------------------------------------
echo ""
echo "Case B: unique anchors occur exactly once, and are line-disjoint"
# Without disjointness, one deleted line could remove two anchors and Case C
# would "catch" a mutant for the wrong reason.
case_b() {
  local label f a n line body hits collisions
  for label in "${LABELS[@]}"; do
    f="$(skill_file "$label")"
    unique_for "$label"
    for a in "${UNIQUE[@]}"; do
      inc
      n="$(count_body_lines "$f" "$a")"
      if [ "$n" -eq 1 ]; then
        pass_msg "$label: anchor occurs on exactly 1 body line: $a"
      else
        fail_msg "$label: anchor occurs on $n body lines (want exactly 1): $a"
      fi
    done

    body="$(skill_body "$f")"
    collisions=""
    while IFS= read -r line; do
      hits=0
      for a in "${UNIQUE[@]}"; do
        if str_has "$line" "$a"; then hits=$((hits + 1)); fi
      done
      if [ "$hits" -ge 2 ]; then collisions="$collisions [$line]"; fi
    done <<< "$body"
    inc
    if [ -z "$collisions" ]; then
      pass_msg "$label: no body line carries two unique anchors (deletions are independent)"
    else
      fail_msg "$label: body line(s) carry 2+ unique anchors, so one deletion drops both:$collisions"
    fi
  done
}
case_b

# ---------------------------------------------------------------------------
echo ""
echo "Case C: per-anchor deletion battery — deletion removes THAT anchor only"
# Tightened past "exit non-zero": (i) the anchor must be present BEFORE the
# mutation or the control is vacuous, (ii) it must be gone after, and (iii)
# every OTHER unique anchor of that file must keep the SAME body-line count —
# a count comparison, not mere presence, so a partial collateral deletion is
# still caught. Message wording deliberately excludes the Case A RED signal.
case_c() {
  local label f a other mut idx n_before n_after lost
  for label in "${LABELS[@]}"; do
    f="$(skill_file "$label")"
    unique_for "$label"
    idx=0
    for a in "${UNIQUE[@]}"; do
      idx=$((idx + 1))
      mut="$TMP/c-$label-$idx.md"

      inc
      if skill_body_has "$f" "$a"; then
        pass_msg "$label/c$idx: C(i) precondition met — anchor present pre-mutation: $a"
      else
        fail_msg "$label/c$idx: C(i) precondition unmet — anchor NOT present pre-mutation, control is vacuous: $a"
      fi

      mut_drop_lines "$f" "$mut" "$a"

      inc
      if skill_body_has "$mut" "$a"; then
        fail_msg "$label/c$idx: C(ii) deleting the anchor left it present in the body: $a"
      else
        pass_msg "$label/c$idx: C(ii) deleted anchor is absent from the mutant: $a"
      fi

      lost=""
      for other in "${UNIQUE[@]}"; do
        if [ "$other" = "$a" ]; then continue; fi
        n_before="$(count_body_lines "$f" "$other")"
        n_after="$(count_body_lines "$mut" "$other")"
        if [ "$n_before" != "$n_after" ]; then
          lost="$lost [$other: $n_before->$n_after]"
        fi
      done
      inc
      if [ -z "$lost" ]; then
        pass_msg "$label/c$idx: C(iii) no collateral loss — every other unique anchor kept its body-line count"
      else
        fail_msg "$label/c$idx: C(iii) deleting '$a': COLLATERAL LOSS — deleting '$a' also destroyed:$lost"
      fi
    done
  done
}
case_c

# ---------------------------------------------------------------------------
echo ""
echo "Case D: the ledger row lives INSIDE the canonical plan template fence"
# Prose alone must not satisfy the requirement: `**RED/GREEN ledger:**` has to
# appear inside the ```markdown fence of plan-issue that carries
# `## Implementation Plan`, because execute-issue-plan reads the template.

# Emit the ```markdown fenced block of <file>'s BODY that contains
# `## Implementation Plan`. Fence markers may carry the file's 3-space indent.
# Here-string + flag walker; never `skill_body | awk`.
extract_impl_template() {
  local f="$1" body line trimmed infence=0 buf="" found=""
  body="$(skill_body "$f")"
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [ "$infence" -eq 0 ]; then
      case "$trimmed" in
        '```markdown'*) infence=1; buf="" ;;
      esac
      continue
    fi
    case "$trimmed" in
      '```'*)
        infence=0
        case "$buf" in
          *'## Implementation Plan'*) found="$buf" ;;
        esac
        continue
        ;;
    esac
    buf="$buf$line"$'\n'
  done <<< "$body"
  printf '%s' "$found"
}

case_d() {
  local tmpl mut mut_tmpl
  # The template-row form ONLY. The contract subsection's backticked reference
  # (`**`**RED/GREEN ledger:**` section (required for every plan ...`) does not
  # contain this literal, so it survives the mutation — that is the point: the
  # negative control proves prose alone does not satisfy Case D.
  local drop_needle='**RED/GREEN ledger:** (required when the plan has'

  tmpl="$(extract_impl_template "$SKILL_PI")"

  # D(0) non-vacuity: an empty extraction would make D(1) fail for the wrong
  # reason and make D(3) pass vacuously.
  inc
  if [ -n "$tmpl" ] && str_has "$tmpl" '## Implementation Plan'; then
    pass_msg "D(0): canonical \`\`\`markdown plan template extracted from the plan-issue body"
  else
    fail_msg "D(0): could not extract the canonical \`\`\`markdown plan template — Case D cannot run"
  fi

  inc
  if str_has "$tmpl" "$PI_SECTION"; then
    pass_msg "D(1): the ledger row is INSIDE the canonical plan template fence"
  else
    fail_msg "D(1): the canonical plan template fence does NOT carry the ledger row: $PI_SECTION"
  fi

  # Negative control: drop the template row only.
  mut="$TMP/d-mutant.md"
  mut_drop_lines "$SKILL_PI" "$mut" "$drop_needle"

  inc
  if diff -q "$SKILL_PI" "$mut" > /dev/null 2>&1; then
    fail_msg "D(2): negative control is vacuous — the mutant is byte-identical to the original (nothing to delete)"
  else
    pass_msg "D(2): negative control applied — the template row was deleted"
  fi

  mut_tmpl="$(extract_impl_template "$mut")"
  inc
  if str_has "$mut_tmpl" "$PI_SECTION"; then
    fail_msg "D(3): negative control NOT CAUGHT — the template fence still carries the ledger row after deleting it"
  else
    pass_msg "D(3): negative control CAUGHT — deleting the template row empties the fence of the ledger row"
  fi
}
case_d

# ---------------------------------------------------------------------------
echo ""
echo "Case E: #1218 anchors are not collided with by the new #1224 prose"
# GREEN at the RED commit BY DESIGN — it pins state that ALREADY holds. It
# exists to go red if the evaluate-issue-plan insertions reintroduce any of the
# eight #1218 anchors as a substring, which would break
# tests/test-evaluator-executable-verification-prose.sh Case B.
case_e() {
  local a n mut
  for a in "${A1218[@]}"; do
    inc
    n="$(count_body_lines "$SKILL_EP" "$a")"
    if [ "$n" -eq 1 ]; then
      pass_msg "E: #1218 anchor still occurs on exactly 1 evaluate-issue-plan body line: $a"
    else
      fail_msg "E: #1218 anchor occurs on $n body lines (want exactly 1) — #1224 prose collided with it: $a"
    fi
  done

  # Negative control (sensitivity): plant a SECOND `not-executed:` body line.
  # If Case E cannot catch this, it cannot catch a real collision either.
  mut="$TMP/e-mutant.md"
  cp "$SKILL_EP" "$mut"
  printf '%s\n' '   - **Planted collision.** not-executed: this line must break Case E.' >> "$mut"
  inc
  if diff -q "$SKILL_EP" "$mut" > /dev/null 2>&1; then
    fail_msg "E: negative control is vacuous — the planted collision changed nothing"
  else
    n="$(count_body_lines "$mut" 'not-executed:')"
    if [ "$n" -eq 1 ]; then
      fail_msg "E: negative control NOT CAUGHT — a planted second 'not-executed:' body line still counted as 1"
    else
      pass_msg "E: negative control CAUGHT — planted collision raises the count to $n"
    fi
  fi
}
case_e

# ---------------------------------------------------------------------------
echo ""
echo "Case F: the ledger header terminates the shared-tests section"
# `**RED/GREEN ledger:**` sits directly after `**Shared tests (split-role):**`
# in the canonical template, so it MUST match the parser's section terminator
# (`^\*\*[^*].*:\*\*`) or ledger table rows would leak into the sanctioned
# modify-list that evaluate-issue-pr threads into the W7 split-role gate.
#
# Pipes are permitted ONLY in this extraction, mirroring
# tests/test-eval-shared-tests-parser.sh:12 so the REAL parser is under test.
case_f() {
  local awk_prog result_pos result_neg want_pos
  awk_prog="$(grep -oP "awk '\K[^']+(?=')" "$SKILL_PR" 2>/dev/null | grep 'Shared tests' | head -1)" || true

  inc
  if [ -n "$awk_prog" ]; then
    pass_msg "F(0): extracted the real shared-tests awk parser from $SKILL_PR"
  else
    fail_msg "F(0): could not extract the shared-tests awk parser from $SKILL_PR — Case F cannot run"
    return 0
  fi

  want_pos='tests/test-foo.sh'
  result_pos="$(printf '%s\n' \
    '**Shared tests (split-role):**' \
    '- tests/test-foo.sh' \
    '**RED/GREEN ledger:**' \
    '| test file | red at RED commit | vacuously green until | fully green at |' \
    '|---|---|---|---|' \
    '| `tests/test-bar.sh` | yes — assertion fails | — | Task 3 |' \
    | awk "$awk_prog")"
  inc
  if [ "$result_pos" = "$want_pos" ]; then
    pass_msg "F(1): the ledger header terminates the section — output is exactly '$want_pos'"
  else
    fail_msg "F(1): ledger content leaked into the sanctioned shared-test list; got: '$result_pos' (want '$want_pos')"
  fi

  # Negative control (sensitivity): replace the ledger header with a bullet.
  # The section must then continue and yield BOTH paths — proving F(1) is an
  # assertion that CAN fail rather than one the parser satisfies trivially.
  result_neg="$(printf '%s\n' \
    '**Shared tests (split-role):**' \
    '- tests/test-foo.sh' \
    '- tests/test-leak.sh' \
    '| test file | red at RED commit | vacuously green until | fully green at |' \
    '|---|---|---|---|' \
    '| `tests/test-bar.sh` | yes — assertion fails | — | Task 3 |' \
    | awk "$awk_prog")"
  inc
  if [ "$result_neg" = "$want_pos"$'\n'"tests/test-leak.sh" ]; then
    pass_msg "F(2): negative control CAUGHT — a bullet in place of the ledger header yields both paths"
  else
    fail_msg "F(2): negative control is vacuous — the parser did not extend the section for a bullet; got: '$result_neg'"
  fi
}
case_f

# ---------------------------------------------------------------------------
echo ""
echo "Case G: byte-identical no-op copies must never be reported CAUGHT"
# The vacuity control the whole battery rests on. If `skill_body_has` ever
# regains a pipefail-sensitive pipe, this starts reporting CAUGHT and every
# other control above becomes untrustworthy. Mirrors the M0 reference at
# tests/test-evaluator-executable-verification-prose.sh.
#
# EXPECTED RED at the [split-role-red] commit: inner mode is Case A, and Case A
# is red until both skill bodies carry the anchors, so the no-op reads CAUGHT.
# This case goes green when the last anchor lands — that is the ledger's
# prediction, not a defect in the control.
case_g() {
  local gpi="$TMP/g-pi.md" gep="$TMP/g-ep.md"
  local rep=0 caught=0 rc out

  cp "$SKILL_PI" "$gpi"
  cp "$SKILL_EP" "$gep"

  inc
  if diff -q "$SKILL_PI" "$gpi" > /dev/null 2>&1 && diff -q "$SKILL_EP" "$gep" > /dev/null 2>&1; then
    pass_msg "G(0): copies are byte-identical to the originals"
  else
    fail_msg "G(0): copies are not byte-identical — the no-op control is not a no-op"
  fi

  while [ "$rep" -lt "$NOOP_REPS" ]; do
    out="$TMP/g-$rep.out"
    rc="$(run_inner "$gpi" "$gep" "$out")"
    if [ "$rc" != "0" ] || out_has "$out" "$RED_SIGNAL"; then
      caught=$((caught + 1))
      if [ "$caught" -eq 1 ]; then cp "$out" "$TMP/g-first-catch.out"; fi
    fi
    rep=$((rep + 1))
  done

  inc
  if [ "$caught" -eq 0 ]; then
    pass_msg "G(1): no-op control reported NOT CAUGHT 0/$NOOP_REPS runs"
  else
    fail_msg "G(1): no-op control reported CAUGHT $caught/$NOOP_REPS runs — a byte-identical copy must never be caught"
  fi
}
case_g

# ---------------------------------------------------------------------------
echo ""
echo "Case H: fence-rename mutant — D(0)'s else branch must be reachable (#1232)"
# #1232: literal backticks in D(0)'s pass_msg/fail_msg were parsed as command
# substitution, which swallowed the `else` clause at PARSE time — D(0) always
# reported PASS regardless of whether extract_impl_template actually
# succeeded, and its fail_msg call was dead code. A fence-rename mutant
# (renaming the ```markdown fence so extract_impl_template returns "") must
# produce a genuine `FAIL: D(0)` line, and that child run's own accounting
# must balance: PASS + FAIL == TESTS.
#
# Recurses via LEDGER_SKIP_CASE_H=1 so the child (whose SKILL_PI already
# lacks a ```markdown fence) does not try to rename a fence that is no longer
# there and recurse forever.
case_h() {
  local mut out result tests_n pass_n fail_n rest

  mut="$TMP/h-fence-rename.md"
  sed 's/```markdown/```renamed-fence/' "$SKILL_PI" > "$mut"

  inc
  if diff -q "$SKILL_PI" "$mut" > /dev/null 2>&1; then
    fail_msg "H(0): fence-rename mutant is vacuous — byte-identical to the original, nothing was renamed"
  else
    pass_msg "H(0): fence-rename mutant applied — the \`\`\`markdown fence was renamed"
  fi

  out="$TMP/h-run.out"
  SKILL_PI="$mut" LEDGER_SKIP_CASE_H=1 bash "$SELF" > "$out" 2>&1

  inc
  if out_has "$out" 'FAIL: D(0)'; then
    pass_msg "H(1): D(0)'s else branch is reachable — a real FAIL: D(0) line was printed under the fence-rename mutant"
  else
    fail_msg "H(1): D(0)'s else branch is DEAD — no FAIL: D(0) line under the fence-rename mutant (the #1232 defect)"
  fi

  result="$(parse_run_totals "$out")"
  tests_n="${result%%|*}"
  rest="${result#*|}"
  pass_n="${rest%%|*}"
  fail_n="${rest##*|}"

  inc
  if [ -n "$tests_n" ] && [ -n "$pass_n" ] && [ -n "$fail_n" ] && [ "$((pass_n + fail_n))" -eq "$tests_n" ]; then
    pass_msg "H(2): fence-rename run's own accounting balances — PASS($pass_n) + FAIL($fail_n) == TESTS($tests_n)"
  else
    fail_msg "H(2): fence-rename run's own accounting is UNBALANCED — PASS($pass_n) + FAIL($fail_n) != TESTS($tests_n) (the #1232 defect: a dead branch under-reports)"
  fi
}
if [ "$SKIP_CASE_H" != "1" ]; then
  case_h
fi

# ---------------------------------------------------------------------------
echo ""
echo "Case I: suite self-accounting — PASS + FAIL must equal TESTS"
# The general invariant that caught #1232: any case whose parse error
# swallows an `else` branch calls inc() without a matching pass_msg/fail_msg,
# silently under-reporting PASS+FAIL relative to TESTS. This checks it on
# THIS run's own live counters (snapshotted before this check's own inc call),
# so it generalises to any future dead branch of the same shape, anywhere in
# this suite — not just Case H's fence-rename fixture.
case_i() {
  local snap_tests="$TESTS" snap_pass="$PASS" snap_fail="$FAIL"
  inc
  if [ "$((snap_pass + snap_fail))" -eq "$snap_tests" ]; then
    pass_msg "I: self-accounting holds — PASS($snap_pass) + FAIL($snap_fail) == TESTS($snap_tests)"
  else
    fail_msg "I: self-accounting BROKEN — PASS($snap_pass) + FAIL($snap_fail) != TESTS($snap_tests) — a case incremented TESTS without a matching pass_msg/fail_msg"
  fi
}
case_i

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
