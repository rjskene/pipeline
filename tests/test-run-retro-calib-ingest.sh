#!/bin/bash
set -uo pipefail
#
# Tests for scripts/run-retro.sh's ingestion of the calibration summary
# emitted by scripts/calibration-run.sh --run (issue #1280, tracker #1271,
# spec docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md §8).
#
# Substrate: the shared tests/fixtures/run-retro/ tree copied to a temp dir,
# plus a `calib.txt` holding synthetic CALIB / CALIB-TOTAL lines — exactly the
# block calibration-run.sh tees to docs/retros/calib/<UTC date>.txt. The shared
# fixture dir is NEVER mutated, so tests/test-run-retro.sh (which asserts the
# no-calibration degradation strings against it) stays green.
#
# Two rows flip when the substrate is present:
#   weak-model pass          <- the CALIB `reftest=` atoms   (full report)
#   median path b pr/usd     <- the CALIB `cost=` atoms of the `path=B` rows
#                               (--dump-computed only; the plain and --post
#                               reports never render this key)
# Both must fall back to today's exact `n/a (<reason>)` strings when the
# calibration substrate is missing or carries no CALIB rows — the degradation
# contract in run-retro.sh's header (never fail on missing substrate).
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/run-retro.sh"
FIXTURE_SRC="$ROOT/tests/fixtures/run-retro"

NA_WEAK="n/a (no calibration slate; spec §8 cycle-1 deliverable)"
NA_USD="n/a (no per-issue cost in rows JSON)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIX="$TMP/fixture"
cp -r "$FIXTURE_SRC" "$FIX"

# Synthetic calibration block. path=B costs are 12.00 / 20.00 / 31.00 -> the
# path-B median is 20, which is deliberately DIFFERENT from the median over all
# five rows (12.00) so the assertion pins the `path=` filter, not just "some
# number". reftest atoms: 4 pass of 5.
write_calib() {
  cat > "$FIX/calib.txt" <<'CALIB'
CALIB issue=101 path=A cost=$3.10 wall=420 verdicts=Approved/Approved reftest=pass unexpected-files=0
CALIB issue=102 path=D cost=$5.00 wall=600 verdicts=Approved/Approved reftest=pass unexpected-files=0
CALIB issue=103 path=B cost=$12.00 wall=1800 verdicts=Approved/Approved reftest=pass unexpected-files=0
CALIB issue=104 path=B cost=$20.00 wall=2400 verdicts=Approved/Flagged reftest=fail unexpected-files=2
CALIB issue=105 path=B cost=$31.00 wall=3000 verdicts=Approved/Approved reftest=pass unexpected-files=1
CALIB-TOTAL cost=$71.10 wall=8220 issues=5 reftest-pass=4/5
CALIB
}

retro() { bash "$HELPER" --cycle 0 --fixture "$FIX" "$@" 2>&1; }

expect_line() { # <label> <text> <exact line>
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then pass_msg "$1"; else
    fail_msg "$1 (missing line: $3)"
  fi
}
expect_re() { # <label> <text> <ERE>
  if printf '%s\n' "$2" | grep -qE -- "$3"; then pass_msg "$1"; else
    fail_msg "$1 (no line matching: $3)"
  fi
}
refute_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail_msg "$1 (unexpectedly present: $3)"; else
    pass_msg "$1"
  fi
}

# ---------------------------------------------------------------------------
scenario "Scenario 1: weak-model pass is sourced from the CALIB reftest atoms"
# ---------------------------------------------------------------------------
write_calib
REPORT="$(retro)"

expect_line "weak-model row renders <pass>/<total> from the reftest atoms" \
  "$REPORT" "weak-model pass: 4/5"
refute_sub "weak-model row drops the no-calibration-slate placeholder" \
  "$REPORT" "$NA_WEAK"

# ---------------------------------------------------------------------------
scenario "Scenario 2: median path b pr/usd is sourced from the CALIB cost atoms"
# ---------------------------------------------------------------------------
DUMP="$(retro --dump-computed)"

expect_re "median path b \$ is the median of the path=B CALIB cost atoms" \
  "$DUMP" '^COMPUTED median path b pr/usd = 20(\.0+)?$'
refute_sub "median path b \$ drops the no-per-issue-cost placeholder" \
  "$DUMP" "$NA_USD"
refute_sub "non-B CALIB rows do not shift the path-B median" \
  "$DUMP" "COMPUTED median path b pr/usd = 12"

# ---------------------------------------------------------------------------
scenario "Scenario 3: no calibration substrate keeps today's n/a strings"
# ---------------------------------------------------------------------------
rm -f "$FIX/calib.txt"
REPORT_NA="$(retro)"
DUMP_NA="$(retro --dump-computed)"

expect_line "absent calib.txt keeps the weak-model n/a reason verbatim" \
  "$REPORT_NA" "weak-model pass: $NA_WEAK"
expect_line "absent calib.txt keeps the pr/usd n/a reason verbatim" \
  "$DUMP_NA" "COMPUTED median path b pr/usd = $NA_USD"

# ---------------------------------------------------------------------------
scenario "Scenario 4: a calib.txt with no CALIB rows degrades, never fails"
# ---------------------------------------------------------------------------
printf 'calibration aborted before the first issue\n' > "$FIX/calib.txt"
REPORT_EMPTY="$(retro)"
RC_EMPTY=$?
DUMP_EMPTY="$(retro --dump-computed)"

if [ "$RC_EMPTY" -eq 0 ]; then
  pass_msg "a CALIB-row-free calib.txt still exits 0"
else
  fail_msg "a CALIB-row-free calib.txt must not fail the retro (rc=$RC_EMPTY)"
fi
expect_line "a CALIB-row-free calib.txt keeps the weak-model n/a reason" \
  "$REPORT_EMPTY" "weak-model pass: $NA_WEAK"
expect_line "a CALIB-row-free calib.txt keeps the pr/usd n/a reason" \
  "$DUMP_EMPTY" "COMPUTED median path b pr/usd = $NA_USD"

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "PASS: $PASS  FAIL: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
