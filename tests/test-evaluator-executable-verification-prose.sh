#!/bin/bash
set -euo pipefail

# Body-scoped prose guard for issue #1218: both evaluator skills must carry the
# canonical `## Executable verification` block, the per-skill scoping bullet,
# the Phase pointer bullet, and the `**Guard claims verified:**` report row.
#
# THIS TEST IS ABOUT VACUOUS GUARDS, SO IT MUST NOT BE ONE. Three properties
# are engineered in and are themselves asserted:
#
#   1. BODY-SCOPED. Every presence assertion runs against `skill_body`, never
#      the whole file — the issue's own anecdote is a whole-file SKILL.md clause
#      guard that stayed green with the body clause deleted because the YAML
#      frontmatter `description:` satisfied it. Case D plants exactly that decoy
#      and proves it is rejected; Case E proves the stripper is not a no-op.
#
#   2. NO PIPES ANYWHERE. `skill_body <pipe> grep -q` SIGPIPEs the upstream awk
#      and returns 141 under `set -o pipefail`, so a PRESENT anchor reports
#      absent (measured 220 false-absents / 2800 calls). That flake makes the
#      negative controls pass vacuously. Case H mechanically re-asserts the ban
#      over this file and the helper — including diagnostic dumps, where a
#      `diff <pipe> head` reproduced rc=141.
#
#   3. CONTROLS NAME THEIR ANCHOR. No control is satisfied by "exit non-zero":
#      an infrastructure error would satisfy that. Every mutant (Case J) must
#      return rc=1, must name the anchor it deleted, and must NOT name any
#      anchor it did not delete. Each of the three deliverables — the canonical
#      block, the pointer bullet, the scoping bullet — is pinned INDEPENDENTLY,
#      because in an earlier iteration deleting either bullet left this guard
#      green. Case M0 is the no-op control: a byte-identical copy of the file
#      must be reported NOT CAUGHT on every one of N repetitions.
#
# Re-run the whole battery against edited copies with SKILL_PLAN / SKILL_PR.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "$0")"
HELPER_LIB="$SCRIPT_DIR/_lib/skill-body.sh"

if [ ! -f "$HELPER_LIB" ]; then
  echo "ERROR: helper library not found at $HELPER_LIB" >&2
  exit 1
fi
# shellcheck source=_lib/skill-body.sh
source "$HELPER_LIB"

SKILL_PLAN="${SKILL_PLAN:-$SCRIPT_DIR/../skills/evaluate-issue-plan/SKILL.md}"
SKILL_PR="${SKILL_PR:-$SCRIPT_DIR/../skills/evaluate-issue-pr/SKILL.md}"

# Inner mode: run ONLY Case A (the anchor-presence guard). The mutation cases
# re-invoke this file in inner mode against mutated copies, so inner mode must
# never recurse.
INNER="${EVAL_EXEC_VERIF_INNER:-0}"
NOOP_REPS="${EVAL_EXEC_VERIF_NOOP_REPS:-30}"
STABILITY_REPS="${EVAL_EXEC_VERIF_STABILITY_REPS:-25}"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$SKILL_PLAN" "$SKILL_PR"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: SKILL.md not found at $f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Anchor set: seven shared + one per-file.
# ---------------------------------------------------------------------------
# Anchor 1 is the FULL heading line on purpose: a bare `## Executable
# verification` would also be matched by a backticked cross-reference
# elsewhere in the body, so deleting the real heading would not be caught.
A_HEADING='## Executable verification (guard / gate / matcher / assertion / security claims)'
A_CLOSING='A guard that passes is not evidence until you have seen it fail on something.'
A_TRIGGER='**Trigger (mechanical'
A_NEGCTL='**Run a negative control.**'
A_NOTEXEC='not-executed:'
A_ROW='**Guard claims verified:**'
A_POINTER='**Executable verification (#1218):**'
A_SCOPE_PLAN='**Scope at plan-eval time.**'
A_SCOPE_PR='**Scope at pr-eval time.**'

SHARED_ANCHORS=(
  "$A_HEADING"
  "$A_CLOSING"
  "$A_TRIGGER"
  "$A_NEGCTL"
  "$A_NOTEXEC"
  "$A_ROW"
  "$A_POINTER"
)

# Anchors that must live INSIDE the canonical block (Case G boundary control).
IN_BLOCK_ANCHORS=("$A_HEADING" "$A_TRIGGER" "$A_NEGCTL" "$A_NOTEXEC" "$A_CLOSING")
# Anchors that must live OUTSIDE it.
OUT_BLOCK_ANCHORS=("$A_ROW" "$A_POINTER")

LABELS=(plan pr)

skill_file() {
  case "$1" in
    plan) printf '%s' "$SKILL_PLAN" ;;
    pr)   printf '%s' "$SKILL_PR" ;;
    *)    echo "ERROR: unknown label $1" >&2; return 1 ;;
  esac
}

scope_anchor() {
  case "$1" in
    plan) printf '%s' "$A_SCOPE_PLAN" ;;
    pr)   printf '%s' "$A_SCOPE_PR" ;;
    *)    echo "ERROR: unknown label $1" >&2; return 1 ;;
  esac
}

# Populates the global ANCHORS array for <label>.
anchors_for() {
  ANCHORS=("${SHARED_ANCHORS[@]}" "$(scope_anchor "$1")")
}

# ---------------------------------------------------------------------------
# Case A — POSITIVE. The only case that emits `missing anchor in body of`,
# which is this suite's RED signal (8 anchors x 2 files = 16 lines at RED).
# ---------------------------------------------------------------------------
case_a() {
  local label f a
  for label in "${LABELS[@]}"; do
    f="$(skill_file "$label")"
    anchors_for "$label"
    for a in "${ANCHORS[@]}"; do
      inc
      if skill_body_has "$f" "$a"; then
        pass_msg "$label: anchor present in body: $a"
      else
        fail_msg "$label: missing anchor in body of $f: $a"
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
# Pipe-free primitives. Nothing below may use a shell pipeline: `cmd | grep`,
# `cmd | head`, `diff | head` all SIGPIPE their producer and return 141 under
# `set -o pipefail`, which is the exact failure class this issue is about.
# Here-strings (`<<<`) and redirections are fine — they have no producer
# process to kill.
# ---------------------------------------------------------------------------
str_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

file_has_literal() { case "$(<"$1")" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

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

# Extract the canonical block (heading line .. closing-sentence line, inclusive)
# from <file>'s BODY into stdout. Herestring + `done` flag, NEVER
# `skill_body <pipe> awk '... exit'` — that returns 141 under pipefail.
extract_block() {
  local f="$1" body line started=0 finished=0 out=""
  body="$(skill_body "$f")"
  while IFS= read -r line; do
    if [ "$finished" -eq 1 ]; then continue; fi
    if [ "$started" -eq 0 ]; then
      case "$line" in
        *"$A_HEADING"*) started=1 ;;
        *) continue ;;
      esac
    fi
    out="$out$line"$'\n'
    case "$line" in
      *"$A_CLOSING"*) finished=1 ;;
    esac
  done <<< "$body"
  printf '%s' "$out"
}

# --- mutation writers (redirect, never pipe) -------------------------------
mut_drop_lines() { # <src> <dst> <literal>
  local rc=0
  grep -vF -- "$3" "$1" > "$2" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "ERROR: grep failed (rc=$rc) building mutant $2" >&2
    return 1
  fi
  return 0
}

mut_drop_block() { # <src> <dst> — delete heading..closing inclusive
  awk -v h="$A_HEADING" -v c="$A_CLOSING" '
    del == 0 && index($0, h) > 0 { del = 1 }
    del == 1 { if (index($0, c) > 0) del = 0; next }
    { print }
  ' "$1" > "$2"
}

mut_closing_to_frontmatter() { # <src> <dst> — the frontmatter-satisfaction decoy
  awk -v c="$A_CLOSING" '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm && $0 == "---"      { fm = 0; print; next }
    fm && /^description:/  { print $0 " " c; next }
    !fm && index($0, c) > 0 { next }
    { print }
  ' "$1" > "$2"
}

mut_gut_block_clauses() { # <src> <dst> — the M6 drift mutation, one file only
  awk '
    /^[[:space:]]*3\. \*\*Assertion pinning\*\*/ { next }
    /^[[:space:]]*4\. \*\*Security claim\*\*/ { next }
    index($0, "**Same result on both means UNVERIFIED.**") > 0 { next }
    index($0, "**Vacuity check on REDs.**") > 0 { next }
    { print }
  ' "$1" > "$2"
}

# Run this file in inner mode against <plan-file> <pr-file>, capturing combined
# output into <outfile>. Echoes the exit code.
run_inner() {
  local rc=0
  EVAL_EXEC_VERIF_INNER=1 SKILL_PLAN="$1" SKILL_PR="$2" bash "$SELF" > "$3" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# ---------------------------------------------------------------------------
echo "Case A: every anchor is present in the BODY of both evaluator skills"
case_a

# ---------------------------------------------------------------------------
echo ""
echo "Case B: anchors are line-disjoint and occur exactly once per body"
# Without this, one deleted line could remove two anchors and Case C/J would
# "catch" a mutant for the wrong reason.
case_b() {
  local label f a n line body hits collisions
  for label in "${LABELS[@]}"; do
    f="$(skill_file "$label")"
    anchors_for "$label"
    for a in "${ANCHORS[@]}"; do
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
      for a in "${ANCHORS[@]}"; do
        if str_has "$line" "$a"; then hits=$((hits + 1)); fi
      done
      if [ "$hits" -ge 2 ]; then collisions="$collisions [$line]"; fi
    done <<< "$body"
    inc
    if [ -z "$collisions" ]; then
      pass_msg "$label: no body line carries two anchors (deletions are independent)"
    else
      fail_msg "$label: body line(s) carry 2+ anchors, so one deletion drops both:$collisions"
    fi
  done
}
case_b

# ---------------------------------------------------------------------------
echo ""
echo "Case C: per-anchor deletion battery — deletion removes THAT anchor only"
# Tightened past "exit non-zero": (a) the targeted anchor must be gone AND
# (b) every other anchor must survive. An infrastructure error that mangles the
# file fails (b) loudly instead of masquerading as a catch.
case_c() {
  local label f a other mut idx=0 lost
  for label in "${LABELS[@]}"; do
    f="$(skill_file "$label")"
    anchors_for "$label"
    for a in "${ANCHORS[@]}"; do
      idx=$((idx + 1))
      mut="$TMP/c-$label-$idx.md"

      # Precondition: the anchor must be present BEFORE the mutation, else the
      # "absent afterwards" assertion is vacuously true. Deliberately worded so
      # it does not contain Case A's `missing anchor in body of` RED signal.
      inc
      if skill_body_has "$f" "$a"; then
        pass_msg "$label/c$idx: precondition met (anchor present pre-mutation): $a"
      else
        fail_msg "$label/c$idx: precondition unmet, control is vacuous (anchor absent pre-mutation): $a"
      fi

      mut_drop_lines "$f" "$mut" "$a"

      inc
      if skill_body_has "$mut" "$a"; then
        fail_msg "$label/c$idx: deleting the anchor left it present in the body: $a"
      else
        pass_msg "$label/c$idx: deleted anchor is absent: $a"
      fi

      lost=""
      for other in "${ANCHORS[@]}"; do
        if [ "$other" = "$a" ]; then continue; fi
        if ! skill_body_has "$mut" "$other"; then lost="$lost [$other]"; fi
      done
      inc
      if [ -z "$lost" ]; then
        pass_msg "$label/c$idx: no collateral anchor loss"
      else
        fail_msg "$label/c$idx: mutant collaterally lost:$lost"
      fi
    done
  done
}
case_c

# ---------------------------------------------------------------------------
echo ""
echo "Case D: frontmatter-satisfaction decoy is rejected"
# The issue's own anecdote, mechanised: move the closing sentence out of the
# body and into the frontmatter `description:`. A whole-file grep still finds
# it; the body-scoped helper must not. BOTH halves are asserted, so the case
# cannot pass because the mutation silently failed to apply.
case_d() {
  local label f mut
  for label in "${LABELS[@]}"; do
    f="$(skill_file "$label")"
    mut="$TMP/d-$label.md"
    mut_closing_to_frontmatter "$f" "$mut"

    inc
    if skill_body_has "$f" "$A_CLOSING"; then
      pass_msg "$label: precondition met (closing sentence in body pre-mutation)"
    else
      fail_msg "$label: precondition unmet, decoy control is vacuous (closing sentence not in body pre-mutation)"
    fi

    inc
    if file_has_literal "$mut" "$A_CLOSING"; then
      pass_msg "$label: decoy applied — whole-file scan still finds the sentence in frontmatter"
    else
      fail_msg "$label: decoy did NOT apply — sentence absent from the whole mutated file"
    fi

    inc
    if skill_body_has "$mut" "$A_CLOSING"; then
      fail_msg "$label: frontmatter decoy ACCEPTED — a body clause guard here would pass with the clause deleted"
    else
      pass_msg "$label: frontmatter decoy rejected by the body-scoped helper"
    fi
  done
}
case_d

# ---------------------------------------------------------------------------
echo ""
echo "Case E: the frontmatter stripper is not a no-op"
# If skill_body were `cat`, Case D would pass vacuously. Both skills carry
# `disable-model-invocation:` in frontmatter and `## Boot` in the body.
case_e() {
  local label f body
  for label in "${LABELS[@]}"; do
    f="$(skill_file "$label")"
    body="$(skill_body "$f")"

    inc
    if file_has_literal "$f" "disable-model-invocation:"; then
      pass_msg "$label: precondition met (frontmatter carries disable-model-invocation:)"
    else
      fail_msg "$label: precondition unmet, stripper control is vacuous (no disable-model-invocation: in file)"
    fi

    inc
    if str_has "$body" "disable-model-invocation:"; then
      fail_msg "$label: stripper is a no-op — frontmatter key survived into the body"
    else
      pass_msg "$label: frontmatter stripped from body"
    fi

    inc
    if str_has "$body" "## Boot"; then
      pass_msg "$label: stripper preserved the body (## Boot present)"
    else
      fail_msg "$label: stripper over-stripped — body lost ## Boot"
    fi
  done
}
case_e

# ---------------------------------------------------------------------------
echo ""
echo "Case F: helper is deterministic — no false-absents (SIGPIPE control)"
# Synthetic fixtures with KNOWN-present anchors, so this control has teeth
# whether or not the deliverable has landed. A `<pipe> grep -qF` helper reports
# a present anchor absent ~8% of calls; this loop makes that visible instead of
# letting it corrupt the negative controls.
FIXDIR="$TMP/fixtures"
mkdir -p "$FIXDIR"

write_good_fixture() { # <path>
  cat > "$1" <<EOF
---
name: fake-skill
description: a synthetic fixture with no anchors in the description
disable-model-invocation: false
---

## Boot

filler line

$A_HEADING

$A_TRIGGER) — filler
- $A_NEGCTL Filler.
- **No silent fallback to reading.** Report \`$A_NOTEXEC <reason>\`.

$A_CLOSING

$A_SCOPE_PLAN Filler.
$A_SCOPE_PR Filler.

   - $A_POINTER filler sentence.

$A_ROW (filler)
EOF
}

case_f() {
  local good="$FIXDIR/good.md" a rep absent=0 total=0
  write_good_fixture "$good"

  local FIXTURE_ANCHORS=(
    "$A_HEADING" "$A_CLOSING" "$A_TRIGGER" "$A_NEGCTL"
    "$A_NOTEXEC" "$A_ROW" "$A_POINTER" "$A_SCOPE_PLAN"
  )
  rep=0
  while [ "$rep" -lt "$STABILITY_REPS" ]; do
    for a in "${FIXTURE_ANCHORS[@]}"; do
      total=$((total + 1))
      if ! skill_body_has "$good" "$a"; then absent=$((absent + 1)); fi
    done
    rep=$((rep + 1))
  done
  inc
  if [ "$absent" -eq 0 ]; then
    pass_msg "helper false-absents: 0/$total over $STABILITY_REPS reps"
  else
    fail_msg "helper false-absents: $absent/$total over $STABILITY_REPS reps — the helper is flaky (pipefail/SIGPIPE?)"
  fi

  # Not constant-true: an anchor that is genuinely absent must report absent.
  inc
  if skill_body_has "$good" "THIS-LITERAL-IS-NOWHERE-IN-THE-FIXTURE-1218"; then
    fail_msg "helper is constant-true — reported a nonexistent literal as present"
  else
    pass_msg "helper rejects a literal that is genuinely absent"
  fi
}
case_f

# ---------------------------------------------------------------------------
echo ""
echo "Case I: planted decoys are rejected, genuine text is accepted"
case_i() {
  local good="$FIXDIR/good.md" fm="$FIXDIR/decoy-frontmatter.md"
  local short="$FIXDIR/decoy-short-heading.md" split="$FIXDIR/decoy-split.md"
  local hr="$FIXDIR/decoy-hrule.md" a

  write_good_fixture "$good"

  # Positive control for the whole decoy battery: genuine body text is accepted.
  local FIXTURE_ANCHORS=(
    "$A_HEADING" "$A_CLOSING" "$A_TRIGGER" "$A_NEGCTL"
    "$A_NOTEXEC" "$A_ROW" "$A_POINTER" "$A_SCOPE_PLAN"
  )
  for a in "${FIXTURE_ANCHORS[@]}"; do
    inc
    if skill_body_has "$good" "$a"; then
      pass_msg "decoy-battery positive control: genuine body anchor accepted: $a"
    else
      fail_msg "decoy-battery positive control FAILED — genuine body anchor rejected: $a"
    fi
  done

  # Decoy 1: every anchor lives ONLY in the frontmatter description.
  {
    printf '%s\n' '---'
    printf '%s' 'description: '
    for a in "${FIXTURE_ANCHORS[@]}"; do printf '%s ' "$a"; done
    printf '\n'
    printf '%s\n' 'disable-model-invocation: false'
    printf '%s\n' '---'
    printf '\n%s\n' '## Boot'
    printf '%s\n' 'body with no anchors at all'
  } > "$fm"
  for a in "${FIXTURE_ANCHORS[@]}"; do
    inc
    if ! file_has_literal "$fm" "$a"; then
      fail_msg "decoy 1 did not apply — anchor missing from the whole decoy file: $a"
    elif skill_body_has "$fm" "$a"; then
      fail_msg "decoy 1 ACCEPTED — frontmatter-only anchor satisfied the body check: $a"
    else
      pass_msg "decoy 1 rejected — frontmatter-only anchor is not a body anchor: $a"
    fi
  done

  # Decoy 2: a short/backticked near-miss heading must not satisfy anchor 1.
  {
    printf '%s\n' '---'
    printf '%s\n' 'description: d'
    printf '%s\n' '---'
    printf '\n%s\n' '## Boot'
    printf '\n%s\n' '## Executable verification'
    printf '%s\n' 'See the `## Executable verification` section (guard / gate).'
  } > "$short"
  inc
  if skill_body_has "$short" '## Executable verification'; then
    if skill_body_has "$short" "$A_HEADING"; then
      fail_msg "decoy 2 ACCEPTED — a short/backticked heading satisfied the full heading anchor"
    else
      pass_msg "decoy 2 rejected — short/backticked heading does not satisfy the full heading anchor"
    fi
  else
    fail_msg "decoy 2 did not apply — the short heading is not even in the decoy body"
  fi

  # Decoy 3: the closing sentence split across two lines must not match.
  {
    printf '%s\n' '---'
    printf '%s\n' 'description: d'
    printf '%s\n' '---'
    printf '\n%s\n' '## Boot'
    printf '%s\n' 'A guard that passes is not evidence'
    printf '%s\n' 'until you have seen it fail on something.'
  } > "$split"
  inc
  if ! skill_body_has "$split" 'A guard that passes is not evidence'; then
    fail_msg "decoy 3 did not apply — first half of the split sentence is not in the body"
  elif skill_body_has "$split" "$A_CLOSING"; then
    fail_msg "decoy 3 ACCEPTED — a sentence split across two lines satisfied the anchor"
  else
    pass_msg "decoy 3 rejected — a line-split sentence does not satisfy the anchor"
  fi

  # Decoy 4 (inverse): a `---` horizontal rule mid-body must not truncate the
  # body. Guards against an over-eager stripper making Case A vacuously green.
  {
    printf '%s\n' '---'
    printf '%s\n' 'description: d'
    printf '%s\n' '---'
    printf '\n%s\n' '## Boot'
    printf '\n%s\n' '---'
    printf '\n%s\n' "$A_HEADING"
  } > "$hr"
  inc
  if skill_body_has "$hr" "$A_HEADING"; then
    pass_msg "decoy 4 rejected — a mid-body --- rule does not truncate the body"
  else
    fail_msg "decoy 4 ACCEPTED — stripper truncated the body at a mid-body --- rule"
  fi
}
case_i

# ---------------------------------------------------------------------------
echo ""
echo "Case G: the canonical block is byte-identical across both evaluators"
case_g() {
  local bp br a gut="$TMP/g-gutted.md"
  local fp fr
  fp="$(skill_file plan)"
  fr="$(skill_file pr)"
  bp="$(extract_block "$fp")"
  br="$(extract_block "$fr")"

  printf '%s' "$bp" > "$TMP/g-plan.block"
  printf '%s' "$br" > "$TMP/g-pr.block"

  # Non-vacuity of the extraction: empty blocks would `diff` clean.
  local extracted_ok=1
  for a in "${IN_BLOCK_ANCHORS[@]}"; do
    inc
    if str_has "$bp" "$a"; then
      pass_msg "plan: extracted block contains: $a"
    else
      extracted_ok=0
      fail_msg "plan: extracted block does not contain (block absent or truncated): $a"
    fi
    inc
    if str_has "$br" "$a"; then
      pass_msg "pr: extracted block contains: $a"
    else
      extracted_ok=0
      fail_msg "pr: extracted block does not contain (block absent or truncated): $a"
    fi
  done

  # Boundary control: extraction must stop at the closing sentence, so the
  # out-of-block deliverables must NOT be inside it. Without this, an
  # extract_block that returned the whole body would `diff` clean too.
  for a in "${OUT_BLOCK_ANCHORS[@]}"; do
    inc
    if str_has "$bp" "$a"; then
      fail_msg "plan: extraction over-ran the block boundary — it swallowed: $a"
    else
      pass_msg "plan: extraction stopped at the block boundary (excludes: $a)"
    fi
  done

  inc
  if [ "$extracted_ok" -eq 0 ]; then
    fail_msg "canonical block not extractable from both bodies — drift check cannot run"
  elif diff -q "$TMP/g-plan.block" "$TMP/g-pr.block" > /dev/null 2>&1; then
    pass_msg "canonical block identical in both evaluators"
  else
    fail_msg "canonical block DRIFTED between evaluators"
  fi

  # Negative control (mutant M6): gut four clauses from ONE file's block. The
  # identity check must break. No `diff <pipe> head` diagnostic dump here — that
  # reproduces rc=141 under pipefail.
  mut_gut_block_clauses "$fp" "$gut"
  inc
  if diff -q "$fp" "$gut" > /dev/null 2>&1; then
    fail_msg "M6 negative control is vacuous — the gutting mutation changed nothing"
  else
    pass_msg "M6 negative control applied — clauses removed from one file"
  fi

  local bg
  bg="$(extract_block "$gut")"
  printf '%s' "$bg" > "$TMP/g-gutted.block"
  inc
  if [ "$extracted_ok" -eq 0 ]; then
    fail_msg "M6 negative control could not run — no canonical block to gut"
  elif diff -q "$TMP/g-gutted.block" "$TMP/g-pr.block" > /dev/null 2>&1; then
    fail_msg "M6 NOT CAUGHT — gutting 4 clauses from one block still compared identical; the drift check is not looking"
  else
    pass_msg "M6 caught — gutted block differs from the other evaluator's block"
  fi
}
case_g

# ---------------------------------------------------------------------------
echo ""
echo "Case J: deliverable mutants each return rc=1 naming their own anchor"
# The M0 row is the vacuity control the whole battery rests on: if the helper
# ever regains a pipefail-sensitive pipe, M0 starts reporting CAUGHT and every
# other row below becomes untrustworthy.

# Assert the inner run named exactly the expected anchors, per label.
#   expect_named <mut> <label> <mutfile> <outfile> <anchor>
expect_named() {
  inc
  if out_has "$4" "$2: missing anchor in body of $3: $5"; then
    pass_msg "$1/$2: named the deleted anchor: $5"
  else
    fail_msg "$1/$2: did NOT name the deleted anchor (rc alone is not a catch): $5"
  fi
}
expect_not_named() {
  inc
  if out_has "$4" "$2: missing anchor in body of $3: $5"; then
    fail_msg "$1/$2: collaterally named an anchor it did not delete: $5"
  else
    pass_msg "$1/$2: did not name untargeted anchor: $5"
  fi
}
expect_mutated() { # <mut> <label> <src> <dst>
  inc
  if diff -q "$3" "$4" > /dev/null 2>&1; then
    fail_msg "$1/$2: mutation changed nothing — control is vacuous"
    return 1
  fi
  pass_msg "$1/$2: mutation applied"
  return 0
}
expect_rc() { # <mut> <want> <got>
  inc
  if [ "$3" = "$2" ]; then
    pass_msg "$1: rc=$3 as required"
  else
    fail_msg "$1: rc=$3 (want rc=$2)"
  fi
}

# Assert the mutant named its target anchor and nothing else, per label.
#   assert_only <mut> <label> <mutfile> <outfile> <targets...>
assert_only() {
  local mut="$1" label="$2" mfile="$3" ofile="$4"
  shift 4
  local targets=("$@") a t hit
  for t in "${targets[@]}"; do
    expect_named "$mut" "$label" "$mfile" "$ofile" "$t"
  done
  anchors_for "$label"
  for a in "${ANCHORS[@]}"; do
    hit=0
    for t in "${targets[@]}"; do
      if [ "$a" = "$t" ]; then hit=1; fi
    done
    if [ "$hit" -eq 0 ]; then
      expect_not_named "$mut" "$label" "$mfile" "$ofile" "$a"
    fi
  done
}

fp="$(skill_file plan)"
fr="$(skill_file pr)"

# --- M0: byte-identical no-op copy must be reported NOT CAUGHT, every run ---
m0p="$TMP/m0-plan.md"
m0r="$TMP/m0-pr.md"
cp "$fp" "$m0p"
cp "$fr" "$m0r"

inc
if diff -q "$fp" "$m0p" > /dev/null 2>&1 && diff -q "$fr" "$m0r" > /dev/null 2>&1; then
  pass_msg "M0: copies are byte-identical to the originals"
else
  fail_msg "M0: copies are not byte-identical — the no-op control is not a no-op"
fi

m0_caught=0
m0_rep=0
while [ "$m0_rep" -lt "$NOOP_REPS" ]; do
  m0_out="$TMP/m0-$m0_rep.out"
  m0_rc="$(run_inner "$m0p" "$m0r" "$m0_out")"
  if [ "$m0_rc" != "0" ] || out_has "$m0_out" "missing anchor in body of"; then
    m0_caught=$((m0_caught + 1))
    if [ "$m0_caught" -eq 1 ]; then cp "$m0_out" "$TMP/m0-first-failure.out"; fi
  fi
  m0_rep=$((m0_rep + 1))
done
inc
if [ "$m0_caught" -eq 0 ]; then
  pass_msg "M0 (no-op mutant): reported NOT CAUGHT 0/$NOOP_REPS runs"
else
  fail_msg "M0 (no-op mutant): reported CAUGHT $m0_caught/$NOOP_REPS runs — a byte-identical copy must never be caught"
fi

# --- M1: whole canonical block deleted from both files ---------------------
m1p="$TMP/m1-plan.md"
m1r="$TMP/m1-pr.md"
mut_drop_block "$fp" "$m1p"
mut_drop_block "$fr" "$m1r"
expect_mutated M1 plan "$fp" "$m1p" || true
expect_mutated M1 pr "$fr" "$m1r" || true
m1_out="$TMP/m1.out"
m1_rc="$(run_inner "$m1p" "$m1r" "$m1_out")"
expect_rc M1 1 "$m1_rc"
assert_only M1 plan "$m1p" "$m1_out" "$A_HEADING" "$A_TRIGGER" "$A_NEGCTL" "$A_NOTEXEC" "$A_CLOSING"
assert_only M1 pr "$m1r" "$m1_out" "$A_HEADING" "$A_TRIGGER" "$A_NEGCTL" "$A_NOTEXEC" "$A_CLOSING"

# --- M2: closing sentence moved from body to frontmatter description -------
m2p="$TMP/m2-plan.md"
m2r="$TMP/m2-pr.md"
mut_closing_to_frontmatter "$fp" "$m2p"
mut_closing_to_frontmatter "$fr" "$m2r"
expect_mutated M2 plan "$fp" "$m2p" || true
expect_mutated M2 pr "$fr" "$m2r" || true
m2_out="$TMP/m2.out"
m2_rc="$(run_inner "$m2p" "$m2r" "$m2_out")"
expect_rc M2 1 "$m2_rc"
assert_only M2 plan "$m2p" "$m2_out" "$A_CLOSING"
assert_only M2 pr "$m2r" "$m2_out" "$A_CLOSING"

# --- M3: the Phase pointer bullet deleted (independent pin) ----------------
m3p="$TMP/m3-plan.md"
m3r="$TMP/m3-pr.md"
mut_drop_lines "$fp" "$m3p" "$A_POINTER"
mut_drop_lines "$fr" "$m3r" "$A_POINTER"
expect_mutated M3 plan "$fp" "$m3p" || true
expect_mutated M3 pr "$fr" "$m3r" || true
m3_out="$TMP/m3.out"
m3_rc="$(run_inner "$m3p" "$m3r" "$m3_out")"
expect_rc M3 1 "$m3_rc"
assert_only M3 plan "$m3p" "$m3_out" "$A_POINTER"
assert_only M3 pr "$m3r" "$m3_out" "$A_POINTER"

# --- M4: the per-skill scoping bullet deleted (independent pin) ------------
m4p="$TMP/m4-plan.md"
m4r="$TMP/m4-pr.md"
mut_drop_lines "$fp" "$m4p" "$A_SCOPE_PLAN"
mut_drop_lines "$fr" "$m4r" "$A_SCOPE_PR"
expect_mutated M4 plan "$fp" "$m4p" || true
expect_mutated M4 pr "$fr" "$m4r" || true
m4_out="$TMP/m4.out"
m4_rc="$(run_inner "$m4p" "$m4r" "$m4_out")"
expect_rc M4 1 "$m4_rc"
assert_only M4 plan "$m4p" "$m4_out" "$A_SCOPE_PLAN"
assert_only M4 pr "$m4r" "$m4_out" "$A_SCOPE_PR"

# --- M5: the report-template row deleted (independent pin) -----------------
m5p="$TMP/m5-plan.md"
m5r="$TMP/m5-pr.md"
mut_drop_lines "$fp" "$m5p" "$A_ROW"
mut_drop_lines "$fr" "$m5r" "$A_ROW"
expect_mutated M5 plan "$fp" "$m5p" || true
expect_mutated M5 pr "$fr" "$m5r" || true
m5_out="$TMP/m5.out"
m5_rc="$(run_inner "$m5p" "$m5r" "$m5_out")"
expect_rc M5 1 "$m5_rc"
assert_only M5 plan "$m5p" "$m5_out" "$A_ROW"
assert_only M5 pr "$m5r" "$m5_out" "$A_ROW"

# ---------------------------------------------------------------------------
echo ""
echo "Case H: this suite and its helper contain no shell pipelines"
# The bug this issue is about is a SIGPIPE in the guard's own plumbing, so the
# ban is asserted mechanically rather than trusted to review. Needles are built
# from parts so they never appear literally in this file. Comment lines are
# exempt: prose ABOUT pipes is not a pipe.
case_h() {
  local bar='|' target line stripped cmd needle hits f
  local cmds=(grep head tail awk sed wc cut sort uniq xargs tee diff jq cat printf)
  for f in "$SELF" "$HELPER_LIB"; do
    hits=""
    while IFS= read -r line; do
      stripped="${line#"${line%%[![:space:]]*}"}"
      case "$stripped" in '#'*) continue ;; esac
      for cmd in "${cmds[@]}"; do
        needle="$bar $cmd"
        if str_has "$line" "$needle"; then hits="$hits [$needle]"; fi
        needle="$bar$cmd"
        if str_has "$line" "$needle"; then hits="$hits [$needle]"; fi
      done
    done < "$f"
    inc
    if [ -z "$hits" ]; then
      pass_msg "no pipelines in $(basename "$f")"
    else
      fail_msg "pipeline(s) in $(basename "$f") — SIGPIPE/141 risk under pipefail:$hits"
    fi
  done

  # Non-vacuity: the scanner must actually flag a planted pipeline.
  local decoy="$TMP/h-decoy.sh"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '# a comment mentioning a pipe into grep must NOT be flagged'
    printf '%s\n' 'skill_body "$1" '"$bar"' grep -qF -- "$2"'
  } > "$decoy"
  hits=""
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in '#'*) continue ;; esac
    for cmd in "${cmds[@]}"; do
      needle="$bar $cmd"
      if str_has "$line" "$needle"; then hits="$hits [$needle]"; fi
    done
  done < "$decoy"
  inc
  if [ -n "$hits" ]; then
    pass_msg "pipeline scanner is looking — planted decoy pipeline flagged"
  else
    fail_msg "pipeline scanner is vacuous — it missed a planted decoy pipeline"
  fi
}
case_h

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
