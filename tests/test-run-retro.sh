#!/bin/bash
set -uo pipefail
#
# Tests for scripts/run-retro.sh — the per-cycle evolve-loop retro
# (issue #1272, tracker #1271, spec §4/§7).
#
# Fixture-driven: every scenario runs `--fixture <dir>` so no live `gh`, `git`
# or `cost-latency-report.sh` call is made. See tests/fixtures/run-retro/README.md
# for the substrate contract and the numbers pinned below.
#
# BEHAVIOUR TESTS ONLY. Nothing here greps SKILL.md / CLAUDE.md prose (spec §6).
# The `prose-pinning tests` metric asserted in Scenario 8 is a COUNT PRODUCED BY
# THE SCRIPT UNDER TEST, not an assertion about prose content.
#
# Machine-readable seams the asserts depend on:
#   --dump-baseline  -> `BASELINE <row>/<label> = <value>[ <unit>]` (one per line)
#   --dump-computed  -> `COMPUTED <row>/<label> = <value>[ <unit>]` (one per line)
# Unit-less values carry NO trailing space. `<value>` is either a number or an
# `n/a (<reason>)` string.
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/run-retro.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/run-retro"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

inc_scenario() { echo ""; echo "-- $1 --"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# mkfix <name> [tracker=<file>|none] [toolog=<file>|none] [rm=<basename>]...
# Copies the fixture dir to a temp dir and swaps variant files over the
# canonical names the script reads. Echoes the temp dir path.
mkfix() {
  local name="$1"; shift
  local dir="$TMP_ROOT/$name" v
  rm -rf "$dir"
  cp -r "$FIXTURE_DIR" "$dir"
  while [ $# -gt 0 ]; do
    case "$1" in
      tracker=none) rm -f "$dir/tracker.md" ;;
      tracker=*)    v="${1#tracker=}"; cp "$FIXTURE_DIR/$v" "$dir/tracker.md" ;;
      toolog=none)  rm -f "$dir/tool-use.log" ;;
      toolog=*)     v="${1#toolog=}"; cp "$FIXTURE_DIR/$v" "$dir/tool-use.log" ;;
      rm=*)         rm -f "$dir/${1#rm=}" ;;
    esac
    shift
  done
  printf '%s' "$dir"
}

# has_line <text> <exact line>   — whole-line, fixed-string
has_line() { printf '%s\n' "$1" | grep -qxF "$2"; }
# has_re <text> <ERE>
has_re() { printf '%s\n' "$1" | grep -qE "$2"; }
# has_sub <text> <fixed substring>
has_sub() { printf '%s\n' "$1" | grep -qF "$2"; }
# value_of <dump text> <key>  — echoes the RHS of `COMPUTED <key> = `
value_of() { printf '%s\n' "$1" | sed -n "s|^COMPUTED $2 = ||p" | head -1; }

expect_line() { # <label> <text> <exact line>
  if has_line "$2" "$3"; then pass_msg "$1"; else fail_msg "$1 (missing line: $3)"; fi
}
expect_re() { # <label> <text> <ERE>
  if has_re "$2" "$3"; then pass_msg "$1"; else fail_msg "$1 (no line matching: $3)"; fi
}
expect_sub() { # <label> <text> <substring>
  if has_sub "$2" "$3"; then pass_msg "$1"; else fail_msg "$1 (missing: $3)"; fi
}
refute_sub() { # <label> <text> <substring>
  if has_sub "$2" "$3"; then fail_msg "$1 (unexpectedly present: $3)"; else pass_msg "$1"; fi
}

# ---------------------------------------------------------------------------
# Scenario 1: scaffolding
# ---------------------------------------------------------------------------
inc_scenario "Scenario 1: scaffolding"

if [ -f "$HELPER" ]; then
  pass_msg "script file exists at scripts/run-retro.sh"
else
  fail_msg "script file missing at scripts/run-retro.sh"
fi

if [ -x "$HELPER" ]; then
  pass_msg "script is executable"
else
  fail_msg "script is not executable"
fi

if [ -f "$HELPER" ] && head -1 "$HELPER" | grep -q '^#!/bin/bash'; then
  pass_msg "script has #!/bin/bash shebang"
else
  fail_msg "script missing #!/bin/bash shebang"
fi

# ---------------------------------------------------------------------------
# Scenario 2: --help banner names the stable CLI surface
# ---------------------------------------------------------------------------
inc_scenario "Scenario 2: --help banner"

HELP_OUT="$(bash "$HELPER" --help 2>&1)"
HELP_RC=$?
if [ "$HELP_RC" -eq 0 ]; then
  pass_msg "--help exits 0"
else
  fail_msg "--help exited $HELP_RC (expected 0)"
fi

if printf '%s' "$HELP_OUT" | grep -qi 'usage'; then
  pass_msg "--help prints a usage banner"
else
  fail_msg "--help printed no usage banner (got: $(printf '%s' "$HELP_OUT" | head -1))"
fi

for flag in --cycle --post --tracker --since --write --fixture; do
  if printf '%s' "$HELP_OUT" | grep -qF -- "$flag"; then
    pass_msg "--help banner names $flag"
  else
    fail_msg "--help banner does not name $flag"
  fi
done

# ---------------------------------------------------------------------------
# Scenario 3: non-vacuity control FIRST, then arg validation, then output bound
#
# The three exit-non-zero asserts below are NOT red at the RED commit: `bash
# <missing file>` exits 127, which already satisfies "exits non-zero". They are
# paired with the exits-0 control that runs FIRST — a stub that non-zero-exits
# on everything fails that control. Do not drop the pairing.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 3: arg validation + output bound"

bash "$HELPER" --cycle 1 --fixture "$FIXTURE_DIR" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  pass_msg "non-vacuity control: --cycle 1 --fixture DIR exits 0"
else
  fail_msg "non-vacuity control: --cycle 1 --fixture DIR exited $RC (expected 0)"
fi

bash "$HELPER" --bogus >/dev/null 2>&1
if [ $? -ne 0 ]; then
  pass_msg "--bogus exits non-zero"
else
  fail_msg "--bogus exited 0 (expected non-zero)"
fi

bash "$HELPER" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  pass_msg "bare invocation (missing --cycle) exits non-zero"
else
  fail_msg "bare invocation exited 0 (expected non-zero)"
fi

bash "$HELPER" --cycle abc --fixture "$FIXTURE_DIR" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  pass_msg "--cycle abc exits non-zero"
else
  fail_msg "--cycle abc exited 0 (expected non-zero)"
fi

# `wc -l` over the PIPE (not over a quoted var) so empty output counts 0 lines —
# the `-ge 1` half is the non-vacuity guard; `-le 60` alone passes on no output.
LINES=$(bash "$HELPER" --cycle 0 --fixture "$FIXTURE_DIR" 2>/dev/null | wc -l)
if [ "$LINES" -ge 1 ] && [ "$LINES" -le 60 ]; then
  pass_msg "stdout is bounded to 1..60 lines (got $LINES)"
else
  fail_msg "stdout line count out of the 1..60 bound (got $LINES)"
fi

# Baseline report reused by several scenarios below.
REPORT0="$(bash "$HELPER" --cycle 0 --fixture "$FIXTURE_DIR" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Scenario 4: `## Cycle issues` parse
# ---------------------------------------------------------------------------
inc_scenario "Scenario 4: cycle-issues parse"

expect_line "cycle 0 issue list is exactly 1272 1273 1274" \
  "$REPORT0" "cycle-issues: 1272 1273 1274"

FIX2="$(mkfix two-cycle tracker=tracker-2cycle.md)"
REPORT1="$(bash "$HELPER" --cycle 1 --fixture "$FIX2" 2>/dev/null)"
expect_line "cycle 1 issue list is exactly 1281 1282 (2-cycle tracker)" \
  "$REPORT1" "cycle-issues: 1281 1282"

REPORT0B="$(bash "$HELPER" --cycle 0 --fixture "$FIX2" 2>/dev/null)"
expect_line "cycle 0 list stops at the next 'Cycle ' paragraph (2-cycle tracker)" \
  "$REPORT0B" "cycle-issues: 1272 1273 1274"

REPORT9="$(bash "$HELPER" --cycle 9 --fixture "$FIXTURE_DIR" 2>/dev/null)"
if has_re "$REPORT9" '^cycle-issues:'; then
  if has_re "$REPORT9" '^cycle-issues:.*[0-9]{4}'; then
    fail_msg "cycle 9 (absent) should list no issues"
  else
    pass_msg "cycle 9 (absent) lists no issues"
  fi
else
  fail_msg "cycle 9 emitted no cycle-issues: line at all"
fi

# ---------------------------------------------------------------------------
# Scenario 5: baseline-cell decomposition (--dump-baseline)
#
# The two hardest compound cells of the live #1271 table plus the three other
# multi-atom rows. These pins are what prove the decomposition grammar
# (parenthetical unwrap -> atom split -> numeric-token + unit parse) works;
# whole-cell numeric parsing renders n/a for 13 of the 14 rows.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 5: baseline decomposition"

DUMP_B="$(bash "$HELPER" --cycle 0 --fixture "$FIXTURE_DIR" --dump-baseline 2>/dev/null)"

while IFS= read -r want; do
  [ -z "$want" ] && continue
  expect_line "decomposed: ${want#BASELINE }" "$DUMP_B" "$want"
done <<'BASELINES'
BASELINE median path b pr/loc = 320
BASELINE median path b pr/tokens = 23000000
BASELINE median path b pr/min = 44
BASELINE median path b pr/usd = 55 $
BASELINE median path b pr/tokens/loc = 67000
BASELINE harness mass/skills = 18
BASELINE harness mass/words = 55000
BASELINE harness mass/scripts = 84
BASELINE harness mass/scripts loc = 20000
BASELINE harness mass/hooks = 14
BASELINE harness mass/hooks loc = 5000
BASELINE harness mass/tests = 405
BASELINE harness mass/tests loc = 69000
BASELINE prose-pinning tests/grep skill.md = 165
BASELINE prose-pinning tests/grep claude.md = 38
BASELINE issue-number archaeology in skill bodies/refs = 351
BASELINE issue-number archaeology in skill bodies/distinct = 130
BASELINE doc/behaviour contradictions/value = 4
BASELINES

# ---------------------------------------------------------------------------
# Scenario 6: tracker degradation never fails the run
# ---------------------------------------------------------------------------
inc_scenario "Scenario 6: tracker degradation"

FIX_NOTRACK="$(mkfix no-tracker tracker=none)"
OUT_NOTRACK="$(bash "$HELPER" --cycle 0 --fixture "$FIX_NOTRACK" --dump-baseline 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ]; then
  pass_msg "absent tracker.md still exits 0"
else
  fail_msg "absent tracker.md exited $RC (expected 0)"
fi
expect_sub "absent tracker.md renders the unreadable reason" \
  "$OUT_NOTRACK" "n/a (tracker body unreadable)"

FIX_GARBLED="$(mkfix garbled tracker=tracker-garbled.md)"
OUT_GARBLED="$(bash "$HELPER" --cycle 0 --fixture "$FIX_GARBLED" --dump-baseline 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ]; then
  pass_msg "garbled tracker (no baseline section) still exits 0"
else
  fail_msg "garbled tracker exited $RC (expected 0)"
fi
expect_sub "garbled tracker renders the unreadable reason" \
  "$OUT_GARBLED" "n/a (tracker body unreadable)"

FIX_NONNUM="$(mkfix non-numeric tracker=tracker-nonnumeric.md)"
OUT_NONNUM="$(bash "$HELPER" --cycle 0 --fixture "$FIX_NONNUM" --dump-baseline 2>/dev/null)"
expect_sub "a cell with zero numeric atoms renders the non-numeric reason" \
  "$OUT_NONNUM" "n/a (non-numeric baseline)"
# ...and the OTHER rows still decompose (the non-numeric path is per-row, not global).
expect_line "non-numeric row does not poison the rest of the table" \
  "$OUT_NONNUM" "BASELINE harness mass/skills = 18"

# ---------------------------------------------------------------------------
# Scenario 7: cost / latency rows scoped to the cycle's issues
#
# rows.json holds #1272 + #1273 (in cycle 0) and #9999 (out of cycle), chosen so
# leaking #9999 into the median shifts EVERY metric. See the fixture README.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 7: cost/latency rows scoped to cycle issues"

DUMP_C="$(bash "$HELPER" --cycle 0 --fixture "$FIXTURE_DIR" --dump-computed 2>/dev/null)"

expect_re "median loc over in-cycle issues only = 300" \
  "$DUMP_C" '^COMPUTED median path b pr/loc = 300(\.0)?$'
expect_re "median tokens over in-cycle issues only = 22000000" \
  "$DUMP_C" '^COMPUTED median path b pr/tokens = 22000000(\.0)?$'
expect_re "median tokens/LOC over in-cycle issues only = 70000" \
  "$DUMP_C" '^COMPUTED median path b pr/tokens/loc = 70000(\.0)?$'
expect_re "median wall-clock over in-cycle issues only = 45 min" \
  "$DUMP_C" '^COMPUTED median path b pr/min = 45(\.0)?$'

# Negative controls: the out-of-cycle row must not be in the median.
refute_sub "out-of-cycle issue does not shift the loc median" \
  "$DUMP_C" "COMPUTED median path b pr/loc = 400"
refute_sub "out-of-cycle issue does not shift the tokens/LOC median" \
  "$DUMP_C" "COMPUTED median path b pr/tokens/loc = 80000"

expect_line "no per-issue \$ in the rows JSON renders a named reason" \
  "$DUMP_C" "COMPUTED median path b pr/usd = n/a (no per-issue cost in rows JSON)"

# Cycle-0 issue #1274 has no row in rows.json.
WINDOW_LINE="$(printf '%s\n' "$REPORT0" | grep -F 'n/a (outside PR window)' | head -1)"
if [ -n "$WINDOW_LINE" ]; then
  if printf '%s' "$WINDOW_LINE" | grep -q '1274'; then
    pass_msg "cycle issue with no rows.json row renders n/a (outside PR window) and names #1274"
  else
    fail_msg "n/a (outside PR window) line does not name the missing issue #1274 (got: $WINDOW_LINE)"
  fi
else
  fail_msg "no 'n/a (outside PR window)' line for cycle issue #1274"
fi

FIX_NOROWS="$(mkfix no-rows rm=rows.json)"
OUT_NOROWS="$(bash "$HELPER" --cycle 0 --fixture "$FIX_NOROWS" --dump-computed 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ]; then
  pass_msg "absent rows.json still exits 0"
else
  fail_msg "absent rows.json exited $RC (expected 0)"
fi
expect_sub "absent rows.json renders the no-substrate reason" \
  "$OUT_NOROWS" "n/a (no rows substrate)"

# ---------------------------------------------------------------------------
# Scenario 8: harness-mass rows + baseline/computed join coverage
#
# These are measured off the working tree, which always exists, so they are
# never n/a. The join-coverage assert is the one that fails if the Scenario 5
# decomposition regresses to whole-cell parsing (key spellings stop agreeing).
# ---------------------------------------------------------------------------
inc_scenario "Scenario 8: harness-mass rows + join coverage"

MASS_KEYS=(
  "harness mass/skills"
  "harness mass/words"
  "harness mass/scripts"
  "harness mass/scripts loc"
  "harness mass/hooks"
  "harness mass/hooks loc"
  "harness mass/tests"
  "harness mass/tests loc"
  "prose-pinning tests/grep skill.md"
  "prose-pinning tests/grep claude.md"
  "issue-number archaeology in skill bodies/refs"
  "issue-number archaeology in skill bodies/distinct"
)

# Non-vacuity guard, asserted FIRST: at RED both sides are empty and the
# subset check below would hold trivially (∅ ⊆ ∅). Do not drop this pairing.
FOUND=0
for k in "${MASS_KEYS[@]}"; do
  v="$(value_of "$DUMP_C" "$k")"
  case "$v" in
    ''|*[!0-9]*) ;;
    *) FOUND=$((FOUND + 1)) ;;
  esac
done
if [ "$FOUND" -ge 8 ]; then
  pass_msg "non-vacuity guard: at least 8 harness-mass keys computed as bare integers (got $FOUND)"
else
  fail_msg "non-vacuity guard: only $FOUND harness-mass keys computed as bare integers (need >= 8)"
fi

for k in "${MASS_KEYS[@]}"; do
  v="$(value_of "$DUMP_C" "$k")"
  case "$v" in
    ''|*[!0-9]*) fail_msg "COMPUTED $k is not a bare integer (got: '${v:-<missing>}')" ;;
    *)           pass_msg "COMPUTED $k is a bare integer ($v)" ;;
  esac
done

for k in "${MASS_KEYS[@]}"; do
  if printf '%s\n' "$DUMP_B" | grep -qF "BASELINE $k = "; then
    pass_msg "join coverage: computed key '$k' exists on the baseline side"
  else
    fail_msg "join coverage: computed key '$k' has NO baseline counterpart (key spellings diverged)"
  fi
done

# ---------------------------------------------------------------------------
# Scenario 9: friction denial row is FIELD-SCOPED, never a whole-line grep
#
# hooks/log-tool-use.sh writes `ts \t phase \t tool \t session=<id> \t summary`
# and logs INVOCATIONS only — there is no decision field, so no denial record
# can exist today. A whole-line `grep -c BLOCKED` counts the retro's own
# investigation (the summary field carries the agent's Bash command verbatim).
# ---------------------------------------------------------------------------
inc_scenario "Scenario 9: friction denial row (field-scoped)"

NO_DECISION="n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)"

expect_line "clean tool-use.log renders the no-decision-field reason (not 0)" \
  "$DUMP_C" "COMPUTED friction/denials = $NO_DECISION"

FIX_SUMBLK="$(mkfix summary-blocked toolog=tool-use-summary-blocked.log)"
DUMP_SUMBLK="$(bash "$HELPER" --cycle 0 --fixture "$FIX_SUMBLK" --dump-computed 2>/dev/null)"
expect_line "BLOCKED in the field-5 SUMMARY still renders n/a (self-inflation guard)" \
  "$DUMP_SUMBLK" "COMPUTED friction/denials = $NO_DECISION"

FIX_DENIED="$(mkfix denied toolog=tool-use-denied.log)"
DUMP_DENIED="$(bash "$HELPER" --cycle 0 --fixture "$FIX_DENIED" --dump-computed 2>/dev/null)"
expect_line "field-2 'denied' records are counted (2 in the fixture)" \
  "$DUMP_DENIED" "COMPUTED friction/denials = 2"

DUMP_DENIED_SINCE="$(bash "$HELPER" --cycle 0 --fixture "$FIX_DENIED" --since 2026-09-03 --dump-computed 2>/dev/null)"
expect_line "--since excludes denial records older than the window (2 -> 1)" \
  "$DUMP_DENIED_SINCE" "COMPUTED friction/denials = 1"

# ---------------------------------------------------------------------------
# Scenario 10: HARNESS-FRICTION harvest, compactions, hotfix/manual-merge/human
# ---------------------------------------------------------------------------
inc_scenario "Scenario 10: friction harvest + operator-escape counts"

FRICTION_A="HARNESS-FRICTION: doctor.sh documented a single excluded label | PIPELINE_LABELS_EXCLUDED is pipe-separated"
FRICTION_B="HARNESS-FRICTION: the SessionStart refresh hook claimed staging | the evolve clone runs the evolve branch"

expect_line "HARNESS-FRICTION lines are counted (2 across the cycle's issues)" \
  "$DUMP_C" "COMPUTED friction/harness-friction-lines = 2"
expect_sub "HARNESS-FRICTION line A is echoed verbatim in the report" "$REPORT0" "$FRICTION_A"
expect_sub "HARNESS-FRICTION line B is echoed verbatim in the report" "$REPORT0" "$FRICTION_B"

DUMP_SINCE="$(bash "$HELPER" --cycle 0 --fixture "$FIXTURE_DIR" --since 2026-09-03 --dump-computed 2>/dev/null)"
expect_line "--since excludes HARNESS-FRICTION comments older than the window (2 -> 1)" \
  "$DUMP_SINCE" "COMPUTED friction/harness-friction-lines = 1"

expect_line "compactions have no substrate and say so" \
  "$DUMP_C" "COMPUTED friction/compactions = n/a (no transcript substrate)"

expect_line "hotfix uses counted from prs.json head refs" "$DUMP_C" "COMPUTED friction/hotfix = 1"
expect_line "manual-merge uses counted from prs.json labels" "$DUMP_C" "COMPUTED friction/manual-merge = 1"
expect_line "human-label uses counted from issues.json labels" "$DUMP_C" "COMPUTED friction/human = 1"

# ---------------------------------------------------------------------------
# Scenario 11: escapes — all three sources
#
# Run at cycle 1 against the 2-cycle tracker so a PREVIOUS cycle exists:
#   hotfix     -> PR #2103, head ref feature/hotfix-1283
#   revert     -> PR #2104, conventional-commit `revert:` type
#   later-fix  -> PR #2101 (cycle 1) touches scripts/run-retro.sh, which PR #2001
#                 (cycle 0) also changed. NEGATIVE CONTROL: PR #2102 (cycle 1)
#                 touches only docs/retros/cycle-01.md — disjoint, so the count
#                 must be exactly 1, not 2.
# ---------------------------------------------------------------------------
inc_scenario "Scenario 11: escapes (hotfix, revert, later-fix)"

DUMP_C1="$(bash "$HELPER" --cycle 1 --fixture "$FIX2" --dump-computed 2>/dev/null)"

expect_line "escapes: hotfix PRs counted by head ref" "$DUMP_C1" "COMPUTED escapes/hotfix = 1"
expect_line "escapes: revert PRs counted by conventional-commit type" "$DUMP_C1" "COMPUTED escapes/revert = 1"
expect_line "escapes: later fix PR touching a previous-cycle file counted (disjoint PR excluded)" \
  "$DUMP_C1" "COMPUTED escapes/later-fix = 1"

# ---------------------------------------------------------------------------
# Scenario 12: gate yield, weak-model pass, usage snapshot
# ---------------------------------------------------------------------------
inc_scenario "Scenario 12: gate yield, weak-model, usage snapshot"

expect_re "gate yield renders Flagged/evals as k/n (1 of 3 PR evals)" \
  "$REPORT0" 'Flagged/evals[^0-9]*1/3'
expect_re "gate yield renders Revise/plans as k/n (1 of 4 plan evals)" \
  "$REPORT0" 'Revise/plans[^0-9]*1/4'

WEAK_LINE="$(printf '%s\n' "$REPORT0" | grep -F 'weak-model' | head -1)"
if [ -n "$WEAK_LINE" ]; then
  if printf '%s' "$WEAK_LINE" | grep -qF 'n/a (no calibration slate; spec §8 cycle-1 deliverable)'; then
    pass_msg "weak-model pass row renders the named cycle-1 reason"
  else
    fail_msg "weak-model row present but reason wrong (got: $WEAK_LINE)"
  fi
else
  fail_msg "no weak-model pass row in the report"
fi

expect_re "usage snapshot reads five_hour from the LAST usage-gate record" "$REPORT0" 'five_hour[=: ]+41'
expect_re "usage snapshot reads seven_day from the LAST usage-gate record"  "$REPORT0" 'seven_day[=: ]+63'
expect_re "usage snapshot reads threshold from the LAST usage-gate record"  "$REPORT0" 'threshold[=: ]+80'
refute_sub "usage snapshot does not use the FIRST (stale) record" "$REPORT0" "five_hour=12"

FIX_NOUSAGE="$(mkfix no-usage rm=usage-gate.jsonl)"
REPORT_NOUSAGE="$(bash "$HELPER" --cycle 0 --fixture "$FIX_NOUSAGE" 2>/dev/null)"
expect_sub "absent usage-gate log renders a named reason" \
  "$REPORT_NOUSAGE" "n/a (no usage-gate log)"

# ---------------------------------------------------------------------------
# Scenario 13: deltas are an INNER JOIN on decomposed sub-metric keys
# ---------------------------------------------------------------------------
inc_scenario "Scenario 13: deltas"

expect_re "delta emitted for median path b pr/loc (320 baseline -> 300 computed)" \
  "$REPORT0" '^delta median path b pr/loc\b.*-20'

BKEYS_FILE="$TMP_ROOT/bkeys"
CKEYS_FILE="$TMP_ROOT/ckeys"
printf '%s\n' "$DUMP_B" | sed -n 's|^BASELINE \(.*\) = .*|\1|p' | LC_ALL=C sort -u > "$BKEYS_FILE"
# Only NUMERIC computed values can join — an `n/a (...)` computed value has no delta.
printf '%s\n' "$DUMP_C" | sed -n 's|^COMPUTED \(.*\) = [0-9][0-9.]*\( .*\)\{0,1\}$|\1|p' | LC_ALL=C sort -u > "$CKEYS_FILE"
JOINED=$(LC_ALL=C comm -12 "$BKEYS_FILE" "$CKEYS_FILE" | wc -l)
DELTAS=$(printf '%s\n' "$REPORT0" | grep -c '^delta ')

# Non-vacuity half FIRST: at RED both key sets are empty and the equality below
# holds trivially (0 == 0). Do not drop this pairing.
if [ "$DELTAS" -gt 0 ]; then
  pass_msg "non-vacuity guard: at least one delta line is emitted (got $DELTAS)"
else
  fail_msg "non-vacuity guard: no delta lines emitted"
fi
if [ "$DELTAS" -eq "$JOINED" ]; then
  pass_msg "one delta per joined key (deltas=$DELTAS, |BASELINE ∩ COMPUTED|=$JOINED)"
else
  fail_msg "delta count $DELTAS != joined key count $JOINED (decomposition/join divergence)"
fi

FIX_MISSROW="$(mkfix missing-row tracker=tracker-missing-row.md)"
REPORT_MISSROW="$(bash "$HELPER" --cycle 0 --fixture "$FIX_MISSROW" 2>/dev/null)"
expect_sub "computed key with no baseline row renders a named reason" \
  "$REPORT_MISSROW" "n/a (baseline row not found: harness mass/skills)"

# Baseline-only rows are informational passthroughs: no delta, no n/a noise.
PASSTHRU_LINE="$(printf '%s\n' "$REPORT0" | grep -F 'stage cost share' | head -1)"
if [ -n "$PASSTHRU_LINE" ]; then
  pass_msg "baseline-only row 'stage cost share' is carried as a passthrough"
  if printf '%s' "$PASSTHRU_LINE" | grep -qF 'n/a'; then
    fail_msg "passthrough row 'stage cost share' emits n/a noise (got: $PASSTHRU_LINE)"
  else
    pass_msg "passthrough row 'stage cost share' emits no n/a noise"
  fi
  if has_re "$REPORT0" '^delta stage cost share'; then
    fail_msg "passthrough row 'stage cost share' emitted a delta (it has no computed side)"
  else
    pass_msg "passthrough row 'stage cost share' emits no delta"
  fi
else
  fail_msg "baseline-only row 'stage cost share' is missing from the report"
fi

expect_sub "cycle 0 has no previous cycle and says so" "$REPORT0" "n/a (no previous cycle)"

expect_re "cycle 1 deltas against docs/retros/cycle-00.md" \
  "$REPORT1" '^prev-delta harness mass/skills\b'
refute_sub "cycle 1 does not claim there is no previous cycle" \
  "$REPORT1" "n/a (no previous cycle)"

# ---------------------------------------------------------------------------
# Scenario 14: pending verdicts (cycle N-1 issues measured by 'retro (next cycle)')
# ---------------------------------------------------------------------------
inc_scenario "Scenario 14: pending verdicts"

PENDING="$(printf '%s\n' "$REPORT1" | grep -F 'pending-verdicts:')"
if [ -n "$PENDING" ]; then
  pass_msg "cycle 1 emits a pending-verdicts: line"
  if printf '%s' "$PENDING" | grep -q '1273' && printf '%s' "$PENDING" | grep -q '1274'; then
    pass_msg "pending verdicts name #1273 and #1274 (Measured by: retro (next cycle))"
  else
    fail_msg "pending verdicts missing #1273/#1274 (got: $PENDING)"
  fi
  if printf '%s' "$PENDING" | grep -q '1272'; then
    fail_msg "pending verdicts wrongly include #1272 (Measured by: immediate)"
  else
    pass_msg "pending verdicts exclude #1272 (Measured by: immediate)"
  fi
else
  fail_msg "cycle 1 emitted no pending-verdicts: line"
fi

# ---------------------------------------------------------------------------
# Scenario 15: --post mode (mass + friction only, plus verdict candidates)
# ---------------------------------------------------------------------------
inc_scenario "Scenario 15: --post mode"

FIX_POST="$(mkfix post)"
TREE_BEFORE="$(find "$FIX_POST" -type f | LC_ALL=C sort | xargs md5sum | md5sum)"
POST_OUT="$(bash "$HELPER" --cycle 0 --post --fixture "$FIX_POST" 2>/dev/null)"
POST_RC=$?
TREE_AFTER="$(find "$FIX_POST" -type f | LC_ALL=C sort | xargs md5sum | md5sum)"

if [ "$POST_RC" -eq 0 ]; then
  pass_msg "--post exits 0"
else
  fail_msg "--post exited $POST_RC (expected 0)"
fi

# Must-CONTAIN guards run FIRST — the must-NOT-contain asserts below pass
# vacuously on empty output. Do not drop this pairing.
expect_sub "--post contains the harness-mass rows" "$POST_OUT" "harness mass"
expect_sub "--post contains the friction rows" "$POST_OUT" "friction"
refute_sub "--post omits the cost/latency rows" "$POST_OUT" "median path b pr"
if has_re "$POST_OUT" '^delta '; then
  fail_msg "--post emitted delta lines (deltas are a full-report row)"
else
  pass_msg "--post omits the delta rows"
fi

CAND="$(printf '%s\n' "$POST_OUT" | grep -F 'verdict-candidates:')"
if [ -n "$CAND" ]; then
  pass_msg "--post emits a verdict-candidates: line"
  if printf '%s' "$CAND" | grep -q '1273' && printf '%s' "$CAND" | grep -q '1274'; then
    pass_msg "verdict candidates name this cycle's retro-next-cycle issues (#1273, #1274)"
  else
    fail_msg "verdict candidates missing #1273/#1274 (got: $CAND)"
  fi
  if printf '%s' "$CAND" | grep -q '1272'; then
    fail_msg "verdict candidates wrongly include #1272 (Measured by: immediate)"
  else
    pass_msg "verdict candidates exclude #1272 (Measured by: immediate)"
  fi
else
  fail_msg "--post emitted no verdict-candidates: line"
fi

POST_LINES=$(bash "$HELPER" --cycle 0 --post --fixture "$FIX_POST" 2>/dev/null | wc -l)
if [ "$POST_LINES" -ge 1 ] && [ "$POST_LINES" -le 60 ]; then
  pass_msg "--post stdout is bounded to 1..60 lines (got $POST_LINES)"
else
  fail_msg "--post stdout line count out of the 1..60 bound (got $POST_LINES)"
fi

if [ "$TREE_BEFORE" = "$TREE_AFTER" ]; then
  pass_msg "--post writes nothing to the filesystem (fixture tree byte-identical)"
else
  fail_msg "--post modified the fixture tree"
fi

# ---------------------------------------------------------------------------
# Scenario 16: --write mode
# ---------------------------------------------------------------------------
inc_scenario "Scenario 16: --write mode"

WRITE_TARGET="$TMP_ROOT/retros/cycle-01.md"
rm -rf "$TMP_ROOT/retros"
WRITE_STDOUT="$(bash "$HELPER" --cycle 1 --fixture "$FIX2" --write "$WRITE_TARGET" 2>/dev/null)"
WRITE_RC=$?
WRITE_STDOUT_LINES=$(bash "$HELPER" --cycle 1 --fixture "$FIX2" --write "$WRITE_TARGET" 2>/dev/null | wc -l)

if [ "$WRITE_RC" -eq 0 ]; then
  pass_msg "--write exits 0"
else
  fail_msg "--write exited $WRITE_RC (expected 0)"
fi

if [ -s "$WRITE_TARGET" ]; then
  pass_msg "--write creates a non-empty file (parent dirs created)"
  FILE_LINES=$(wc -l < "$WRITE_TARGET")
  if [ "$WRITE_STDOUT_LINES" -ge 1 ] && [ "$WRITE_STDOUT_LINES" -le 60 ]; then
    pass_msg "--write keeps stdout bounded to 1..60 lines (got $WRITE_STDOUT_LINES)"
  else
    fail_msg "--write stdout line count out of the 1..60 bound (got $WRITE_STDOUT_LINES)"
  fi
  if [ "$FILE_LINES" -ge "$WRITE_STDOUT_LINES" ]; then
    pass_msg "--write file carries the full (untruncated) report (file=$FILE_LINES >= stdout=$WRITE_STDOUT_LINES)"
  else
    fail_msg "--write file ($FILE_LINES lines) is shorter than stdout ($WRITE_STDOUT_LINES lines)"
  fi
else
  fail_msg "--write did not create $WRITE_TARGET"
fi

# Without --write, nothing lands under docs/retros/.
BEFORE_RETROS="$(ls "$REPO_ROOT"/docs/retros/cycle-*.md 2>/dev/null | wc -l)"
bash "$HELPER" --cycle 1 --fixture "$FIX2" >/dev/null 2>&1
AFTER_RETROS="$(ls "$REPO_ROOT"/docs/retros/cycle-*.md 2>/dev/null | wc -l)"
if [ "$BEFORE_RETROS" -eq "$AFTER_RETROS" ]; then
  pass_msg "a run without --write creates no docs/retros/cycle-*.md"
else
  fail_msg "a run without --write created a file under docs/retros/"
fi

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
