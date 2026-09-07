#!/bin/bash
set -uo pipefail
#
# #1300 — ONE TEST FILE PER `bash` INVOCATION.
#
# `bash a.sh b.sh` runs `a.sh` ONLY; `b.sh` arrives as `$1` and is never
# executed. #1291 shipped six of these (three copies each of two distinct
# commands) and every one of them read as a green two-file run. This guard pins
# the rule at its three prose sites and proves the detector actually fires on
# the shapes that caused the incident.
#
# ONE REGEX, TWO NAMED MODES:
#
#   fenced  — only lines inside a ```bash fence. This is the ENFORCER.
#   inline  — every line, fences included. This is the DETECTOR.
#
# WHY THE ENFORCER IS FENCE-SCOPED. The rule text itself quotes the
# anti-pattern (`bash a.sh b.sh` as inline code in prose), so an `inline`
# enforcement arm over skills/ + agents/ would be SELF-TRIPPING — it reports 2
# hits on the patched tree and both are the rule. `fenced` is 0 on the patched
# tree because prose is not a fence. Arm 2's fixture is what proves that zero
# means "clean" rather than "scanner broken".
#
# SCAN ROOT is a positive choice: `skills/*/SKILL.md` + `agents/*.md` are the
# runtime contracts the rule binds. `docs/` is prose, not a contract (and,
# measured, yields 0 under `fenced` anyway).
#
# House shape: PASS/FAIL counters, `[ "$FAIL" -eq 0 ]` tail.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

# ---------------------------------------------------------------------------
# scan <file> <mode:fenced|inline>  -> one `<file>:<line>\t<match>` record per
# OCCURRENCE, in file order.
#
# The regex is a bare `*.sh` WORD directly after `bash`, followed by a second
# bare `*.sh` word. The excluded-character class (space, pipe, semicolon,
# ampersand, less-than, greater-than, backtick) terminates a command or an
# inline-code span; a LEADING `-` on the second word exempts flag arguments
# (`bash a.sh -v b.sh`). `for t in a.sh b.sh; do bash "$t"; done` never matches
# because the word after `bash` is `"$t"`, not a `.sh` literal.
#
# FENCE GRAMMAR (copied from tests/test-skill-fence-positional-args.sh): open on
# /^[[:space:]]*```bash[[:space:]]*$/, close on the next /^[[:space:]]*```[[:space:]]*$/.
# INDENTED fences are included on purpose.
# ---------------------------------------------------------------------------
scan() {
  awk -v mode="$2" '
    function is_open(l)  { return l ~ /^[[:space:]]*```bash[[:space:]]*$/ }
    function is_close(l) { return l ~ /^[[:space:]]*```[[:space:]]*$/ }
    {
      if (mode == "fenced") {
        if (!inb) { if (is_open($0)) inb = 1; next }
        if (is_close($0)) { inb = 0; next }
      }
      s = $0
      while (match(s, /bash[[:space:]]+[^ |;&<>`]*\.sh[[:space:]]+[^-|;&<>`][^ |;&<>`]*\.sh/)) {
        printf "%s:%d\t%s\n", FILENAME, FNR, substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# scan_many <mode> <file>...  -> the concatenated records (empty when clean).
scan_many() {
  local mode="$1" f; shift
  for f in "$@"; do
    [ -f "$f" ] || continue
    scan "$f" "$mode"
  done
}

count_of() { printf '%s' "$1" | grep -c . ; }

# ---------------------------------------------------------------------------
# Arm 2 FIRST — detector fidelity against a mktemp fixture.
#
# Asserted BEFORE the repo sweep: a scanner that finds nothing would make Arm 1
# vacuously green. The fixture lives under `mktemp -d`, NEVER under skills/ — a
# deliberately dirty SKILL.md inside the sweep root could never go green.
#
# Positives are the two DISTINCT #1291 incident commands verbatim, as inline
# code inside prose bullets (which is exactly how they shipped — not fences).
# ---------------------------------------------------------------------------
inc_scenario "Arm 2: detector fidelity (mktemp fixture)"

FIX_DIR="$(mktemp -d)"
trap 'rm -rf "$FIX_DIR"' EXIT

cat > "$FIX_DIR/positive.md" <<'POSFIX'
# positive fixture — the two #1291 incident commands, verbatim, as prose bullets

- Re-run the calibration knobs: `bash tests/test-pipeline-config-calib-knobs.sh tests/test-config-drift-clean.sh` and confirm both are green.
- Then the headless contract: `bash tests/test-fullsend-headless-contract.sh tests/test-fullsend-dispatch-prose-consistency.sh`.
POSFIX

cat > "$FIX_DIR/negative.md" <<'NEGFIX'
# negative fixture — legitimate shapes that must NEVER be reported

- A per-file loop in prose: `for t in tests/a.sh tests/b.sh; do bash "$t"; done`.
- A glob loop in prose: `for t in tests/*.sh; do bash "$t"; done`.
- Chained one-per-invocation: `bash tests/a.sh && bash tests/b.sh`.
- A flag argument, not a second file: `bash tests/a.sh -v tests/b.sh`.
- Piped then sequenced: `bash tests/a.sh | tee out; bash tests/b.sh`.

The same loop inside a fence:

```bash
for t in tests/a.sh tests/b.sh; do bash "$t"; done
```

And split across lines inside a fence:

```bash
for t in tests/a.sh tests/b.sh; do
  bash "$t"
done
```
NEGFIX

POS_INLINE="$(count_of "$(scan "$FIX_DIR/positive.md" inline)")"
POS_FENCED="$(count_of "$(scan "$FIX_DIR/positive.md" fenced)")"
NEG_INLINE="$(count_of "$(scan "$FIX_DIR/negative.md" inline)")"
NEG_FENCED="$(count_of "$(scan "$FIX_DIR/negative.md" fenced)")"

if [ "$POS_INLINE" -eq 2 ]; then
  pass_msg "inline mode reports exactly the 2 incident commands (got $POS_INLINE)"
else
  fail_msg "inline mode reported $POS_INLINE hits on the positive fixture (expected 2)"
fi

# The fence blind spot is PINNED, not left implicit: this is WHY Arm 1 is
# fence-scoped and Arm 2 exists.
if [ "$POS_FENCED" -eq 0 ]; then
  pass_msg "fenced mode is blind to the prose incidents (got $POS_FENCED) — the documented blind spot"
else
  fail_msg "fenced mode reported $POS_FENCED hits on the prose positives (expected 0)"
fi

if [ "$NEG_INLINE" -eq 0 ]; then
  pass_msg "inline mode has no false positives on loops / globs / && / -v / pipes"
else
  fail_msg "inline mode false-positived on the negative fixture ($NEG_INLINE hits)"
fi

if [ "$NEG_FENCED" -eq 0 ]; then
  pass_msg "fenced mode has no false positives on the in-fence loop shapes"
else
  fail_msg "fenced mode false-positived on the negative fixture ($NEG_FENCED hits)"
fi

# ---------------------------------------------------------------------------
# Arm 1 — enforcement sweep. FORWARD regression guard: 0 today, 0 after the
# rule lands, red the moment a fence ships a two-file `bash` run.
# ---------------------------------------------------------------------------
inc_scenario 'Arm 1: no bash fence in skills/ or agents/ runs two test files'

SWEEP_FILES=()
for f in "$REPO_ROOT"/skills/*/SKILL.md "$REPO_ROOT"/agents/*.md; do
  [ -f "$f" ] && SWEEP_FILES+=("$f")
done

if [ "${#SWEEP_FILES[@]}" -ge 2 ]; then
  pass_msg "sweep root resolved ${#SWEEP_FILES[@]} contract files (skills/*/SKILL.md + agents/*.md)"
else
  fail_msg "sweep root resolved ${#SWEEP_FILES[@]} files — glob is broken, the sweep would be vacuous"
fi

REPO_HITS="$(scan_many fenced "${SWEEP_FILES[@]}")"
REPO_COUNT="$(count_of "$REPO_HITS")"
if [ "$REPO_COUNT" -eq 0 ]; then
  pass_msg "no fenced multi-test-file bash invocation in the runtime contracts"
else
  fail_msg "fenced multi-test-file bash invocation(s) found:"
  printf '%s\n' "$REPO_HITS" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Three-site anchors — the rule is stated where the roles that break it read.
#
# The assertion is ANCHOR PRESENCE, not a word count: a cross-file word count
# cannot distinguish the new words from the pre-existing ones. The three
# literals this RED commit expects, and their measured `wc -w` budget (40 total,
# the sanctioned cap), are recorded here verbatim so the budget is auditable:
#
#   skills/plan-issue/SKILL.md  — appended to the EXISTING `**Test changes:**`
#   template line (never a new template line: tests/test-red-green-ledger-prose.sh
#   pins `**RED/GREEN ledger:**` directly after `**Shared tests (split-role):**`):
#     `— one test file per `bash` invocation`                                (7)
#
#   agents/tdd-implementer.md — new Forbidden bullet, immediately BEFORE the
#   `Silently substituting a manual approximation…` bullet:
#     `- Listing several test files after one `bash`: one test file per `bash`
#      invocation, since `bash a.sh b.sh` runs `a.sh` only.`               (21)
#
#   skills/fullsend/SKILL.md — inserted INSIDE the existing physical line,
#   immediately BEFORE its trailing `**Headless:**` clause (a line-end append
#   pulls the clause into headless_sentence() and takes
#   tests/test-fullsend-headless-contract.sh from 35/35 to 33/35):
#     `**One test file per `bash` invocation.** `bash a.sh b.sh` runs only `a.sh`.` (12)
#
# All three are inline code in PROSE, so Arm 1 (fence-scoped) stays 0 while
# `inline` over the patched tree reports 2 — both of them the rule text itself.
# ---------------------------------------------------------------------------
inc_scenario "Rule anchors: plan-issue template, tdd-implementer, fullsend"

for site in "skills/plan-issue/SKILL.md" "agents/tdd-implementer.md" "skills/fullsend/SKILL.md"; do
  if [ -f "$REPO_ROOT/$site" ] && grep -qiF 'one test file per' "$REPO_ROOT/$site"; then
    pass_msg "$site states the one-test-file-per-bash rule"
  else
    fail_msg "$site does not state 'one test file per' anywhere"
  fi
done

# ---------------------------------------------------------------------------
# Arm 3 — plan-draft ADVISORY. ASSERTS NOTHING, by design.
#
# `inline` over `.claude/logs/plan-drafts/*.md` measures 10 on the dogfood host
# today: the six real #1291 incidents plus four self-quotations in this issue's
# own drafts. That directory is gitignored, host-local and append-only, so NO PR
# can drive it to zero — a zero assertion there is permanently red and unfixable.
# The count is a signal, not a gate. Arm 2's fixture carries the burden of
# proving the detector fires on those shapes.
# ---------------------------------------------------------------------------
inc_scenario "Arm 3: plan-draft advisory count (never fails the suite)"

DRAFT_DIR="$REPO_ROOT/.claude/logs/plan-drafts"
if [ -d "$DRAFT_DIR" ]; then
  DRAFT_FILES=()
  for f in "$DRAFT_DIR"/*.md; do
    [ -f "$f" ] && DRAFT_FILES+=("$f")
  done
  if [ "${#DRAFT_FILES[@]}" -gt 0 ]; then
    echo "  PLAN_DRAFT_MULTIFILE_BASH=$(count_of "$(scan_many inline "${DRAFT_FILES[@]}")")"
  else
    echo "  PLAN_DRAFT_MULTIFILE_BASH=n/a"
  fi
else
  echo "  PLAN_DRAFT_MULTIFILE_BASH=n/a"
fi

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
