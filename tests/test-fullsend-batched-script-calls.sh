#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-batched-script-calls.sh — issue #1452.
#
# EVERY per-issue helper-script CALL SITE in fullsend's hot path must sit inside
# a bash fence that batches the whole wave with a `for N in` loop. Calibration
# run 20 measured 66 orchestrator Bash calls for a 6-issue slate; ~36 of them
# were one-script-one-issue invocations at 150-245k context each. Each of the six
# scripts below already emits a one-line `<TOKEN> issue=#N ...` contract line, so
# a wave loop loses no information and drops ~20 API turns.
#
# SCOPE IS FENCE-LEVEL, NOT LOOP-BODY-LEVEL. Wave-invariant setup legitimately
# sits ABOVE the loop inside the same fence (`source .../auto-merge-gate.sh` and
# the `check-capability-refusal.sh --resolve-sources` resolution resolve once per
# wave, not once per issue), so the assertion is "the enclosing FENCE carries a
# `for N in` header".
#
# PROSE IS NOT SCANNED, BY CONSTRUCTION — and that is load-bearing, not lazy:
#   - tests/test-lifecycle-flip-via-script.sh L4 REQUIRES `transition-issue.sh`
#     to be named on three specific SKILL.md PROSE lines (occurrences 1/2/2).
#   - skills/fullsend/references/pr-eval-preflight.md:46 names
#     `bash .../pr-eval-preflight.sh` in prose to explain a hook's reach, in a
#     file with zero bash fences.
# A prose-scanning guard could therefore never go green.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/fullsend/SKILL.md"
REF_DIR="$ROOT/skills/fullsend/references"

# The six scripts calibration run 20 measured as per-issue turn amplifiers.
BASENAMES="transition-issue.sh pr-eval-preflight.sh auto-merge-gate.sh resolve-execute-dispatch.sh finalize-issue-labels.sh rewrite-eval-screenshot-urls.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

if [ ! -f "$SKILL" ]; then
  echo "ERROR: required file not found: $SKILL" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# scan <file> -> one `<line>\t<basename>\t<YES|NO>` record per IN-FENCE call
# site, where the flag reports whether the ENCLOSING fence carries a
# `for N in` header. Fence grammar is the #1281 one (indented fences count —
# the fences nested under numbered list items are exactly the ones at issue).
# ---------------------------------------------------------------------------
scan() {
  awk -v names="$BASENAMES" '
    function is_open(l)  { return l ~ /^[[:space:]]*```bash[[:space:]]*$/ }
    function is_close(l) { return l ~ /^[[:space:]]*```[[:space:]]*$/ }
    function flush_fence(   i) {
      for (i = 1; i <= nc; i++) printf "%d\t%s\t%s\n", cl[i], cn[i], (hasfor ? "YES" : "NO")
      nc = 0; hasfor = 0
    }
    BEGIN { n = split(names, a, " ") }
    {
      if (!inb) { if (is_open($0)) { inb = 1; nc = 0; hasfor = 0 } next }
      if (is_close($0)) { flush_fence(); inb = 0; next }
      if ($0 ~ /^[[:space:]]*for N in /) hasfor = 1
      for (i = 1; i <= n; i++) {
        if ($0 ~ ("(bash|source)[[:space:]][^|]*scripts/" a[i])) {
          nc++; cl[nc] = FNR; cn[nc] = a[i]
        }
      }
    }
    END { if (inb) flush_fence() }
  ' "$1"
}

# ---------------------------------------------------------------------------
scenario "scanner self-test (non-vacuity)"

# The fixture lives under mktemp, NEVER under skills/ — a deliberately dirty
# reference file inside the scan root below could never go green.
SELF_DIR="$(mktemp -d)"
trap 'rm -rf "$SELF_DIR"' EXIT
cat > "$SELF_DIR/fixture.md" <<'SELFTEST'
# self-test fixture

Prose naming `bash "${CLAUDE_PLUGIN_ROOT}/scripts/transition-issue.sh" 1 --to x`
outside any fence is ignored (PROSE-FIXTURE).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-eval-preflight.sh" 1   # BARE-FIXTURE
```

```bash
GATED="1 2 3"
for N in $GATED; do
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/finalize-issue-labels.sh" "$N"   # LOOP-FIXTURE
done
```
SELFTEST

SELF_HITS="$(scan "$SELF_DIR/fixture.md")"
SELF_BARE="$(printf '%s\n' "$SELF_HITS" | grep -c 'NO$' || true)"
SELF_LOOP="$(printf '%s\n' "$SELF_HITS" | grep -c 'YES$' || true)"
BARE_LN="$(grep -n 'BARE-FIXTURE' "$SELF_DIR/fixture.md" | cut -d: -f1)"

if [ "$SELF_BARE" = "1" ]; then
  pass_msg "scanner reports exactly 1 un-batched in-fence call site on the fixture"
else
  fail_msg "scanner reported $SELF_BARE un-batched hits on the fixture (expected 1) — the sweep below is not trustworthy"
fi

if [ "$SELF_LOOP" = "1" ]; then
  pass_msg "scanner reports the batched call site as batched (1 YES record)"
else
  fail_msg "scanner reported $SELF_LOOP batched records on the fixture (expected 1)"
fi

if printf '%s\n' "$SELF_HITS" | grep -qxF "$(printf '%s\tpr-eval-preflight.sh\tNO' "$BARE_LN")"; then
  pass_msg "scanner pins the un-batched call site to fixture line $BARE_LN"
else
  fail_msg "scanner did NOT report the un-batched site at fixture line $BARE_LN (got: ${SELF_HITS:-<none>})"
fi

if printf '%s\n' "$SELF_HITS" | grep -q 'transition-issue.sh'; then
  fail_msg "scanner reported the PROSE call-site line — prose must be ignored by construction"
else
  pass_msg "scanner ignores the prose call-site line (prose is out of scope)"
fi

# ---------------------------------------------------------------------------
scenario "every in-fence call site is batched by a 'for N in' wave loop"

SCAN_FILES="$SKILL"
for f in "$REF_DIR"/*.md; do
  [ -f "$f" ] || continue
  SCAN_FILES="$SCAN_FILES $f"
done

ALL_HITS=""
for f in $SCAN_FILES; do
  hits="$(scan "$f")"
  [ -n "$hits" ] || continue
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    ALL_HITS="${ALL_HITS}${f#"$ROOT"/}	${rec}
"
  done <<< "$hits"
done

OFFENDERS="$(printf '%s' "$ALL_HITS" | grep 'NO$' || true)"
OFF_N="$(printf '%s' "$OFFENDERS" | grep -c . || true)"

if [ "$OFF_N" -eq 0 ]; then
  pass_msg "zero un-batched in-fence call sites across SKILL.md + references/"
else
  fail_msg "$OFF_N in-fence call site(s) are NOT inside a 'for N in' fence — batch them per wave (#1452)"
  printf '%s\n' "$OFFENDERS" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
scenario "non-vacuity floor — each of the six scripts keeps >= 1 in-fence call site"

for b in $BASENAMES; do
  n="$(printf '%s' "$ALL_HITS" | grep -cF "	$b	" || true)"
  if [ "$n" -ge 1 ]; then
    pass_msg "$b has $n in-fence call site(s)"
  else
    fail_msg "$b has ZERO in-fence call sites — deleting a call site must not satisfy the guard trivially"
  fi
done

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
