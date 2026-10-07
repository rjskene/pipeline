#!/usr/bin/env bash
# Unit guard for scripts/evolve-diminishing.sh (#1397).
#
# The diminishing-returns kill switch was prose only: skills/evolve/SKILL.md
# Step 7 said "two verdict lines and neither contains `confirmed` -> pause",
# with no script, no test, and no notion of it in scripts/evolve-loop.sh — so
# the wrapper kept relaunching whatever the verdicts said. This is the coded
# switch both the skill fence and the wrapper call.
#
# Contract under test:
#   evolve-diminishing.sh --tracker N [--comments-file PATH] [--help]
#   * walk the trusted comment stream tracking the current cycle from
#     `^## Cycle <N>`; record `<cycle> <line>` for every `^- verdicts:` line;
#     keep the LAST TWO records.
#   * exactly two records AND neither line contains the fixed string
#     `confirmed` -> print `DIMINISHING cycles=<older>,<newer>`, exit 3.
#   * anything else -> no stdout, exit 0.
#   * fail-OPEN: an empty stream, a failed read, or fewer than two records is
#     exit 0. A kill switch that fired on a `gh` outage would halt a healthy
#     loop.
#   * fail-LOUD on argv: usage on stderr, exit 1. Exit 3 is RESERVED for the
#     DIMINISHING signal, which is why the usage case also asserts rc != 3.
#   * the cycle LABEL degrades to `--` when no heading precedes the line; the
#     fire/no-fire decision never degrades.
#
# `--comments-file` is a TEST-ONLY seam (exactly as evolve-projection.sh
# documents its own): `--tracker` stays the sole production route and always
# goes through filter-trusted-comments.sh, because hooks/enforce-comment-trust.py
# denies a raw `gh … --json comments`. Case (10) is the mechanical control for
# that at the SOURCE level. Every case below builds its own fixture under
# `mktemp -d`; nothing here touches the network or a real tracker.
set -uo pipefail
cd "$(dirname "$0")/.."

# The `cd` above already moved us. NO existence guard on the script: a missing
# script must surface as the genuine interpreter failure (inner rc 127).
ROOT="$(pwd)"
SCRIPT="$ROOT/scripts/evolve-diminishing.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
case_hdr() { echo ""; echo "-- $1 --"; }

ERRFILE="$TMP/stderr.txt"
RC=0; OUT=""; ERR=""
# dimin <args...> — run the script, capturing stdout, stderr and rc separately.
dimin() {
  : > "$ERRFILE"
  OUT="$(bash "$SCRIPT" "$@" 2>"$ERRFILE")"
  RC=$?
  ERR="$(cat "$ERRFILE" 2>/dev/null)"
}
# on <fixture> — the production-shaped call with the TEST-ONLY comments seam.
on() { dimin --tracker 1271 --comments-file "$1"; }

expect_rc() { # <label> <want>
  if [ "$RC" -eq "$2" ]; then pass_msg "$1 (rc=$2)"; else fail_msg "$1 (want rc=$2, got rc=$RC)"; fi
}
refute_rc() { # <label> <forbidden>
  if [ "$RC" -eq "$2" ]; then fail_msg "$1 (rc is $2)"; else pass_msg "$1 (rc=$RC != $2)"; fi
}
expect_eq() { # <label> <actual> <want>
  if [ "${2:-}" = "$3" ]; then pass_msg "$1 ($3)"; else fail_msg "$1 (want '$3', got '${2:-<empty>}')"; fi
}
expect_empty() { # <label> <text>
  if [ -z "$2" ]; then pass_msg "$1"; else fail_msg "$1 (expected empty, got: $2)"; fi
}
expect_nonempty() { # <label> <text>
  if [ -n "$2" ]; then pass_msg "$1"; else fail_msg "$1 (expected non-empty, got nothing)"; fi
}

# --- fixtures: the real tracker cycle-comment shape ------------------------

cat > "$TMP/prose.txt" <<'FIX'
## Cycle 16
- issues: #101 #102
- retro: docs/retros/cycle-16.md
- usage: start five_hour=10 seven_day=20 end five_hour=40 seven_day=28
FIX

cat > "$TMP/one.txt" <<'FIX'
## Cycle 17
- issues: #201 #202
- verdicts: #201 no-effect · #202 regressed
FIX

cat > "$TMP/two-barren.txt" <<'FIX'
## Cycle 16
- verdicts: #101 no-effect · #102 regressed
## Cycle 17
- verdicts: #201 no-effect · #202 no-effect
FIX

cat > "$TMP/newest-confirmed.txt" <<'FIX'
## Cycle 16
- verdicts: #101 no-effect · #102 regressed
## Cycle 17
- verdicts: #201 confirmed · #202 no-effect
FIX

cat > "$TMP/oldest-confirmed.txt" <<'FIX'
## Cycle 16
- verdicts: #101 confirmed · #102 regressed
## Cycle 17
- verdicts: #201 no-effect · #202 no-effect
FIX

cat > "$TMP/four.txt" <<'FIX'
## Cycle 14
- verdicts: #1 no-effect
## Cycle 15
- verdicts: #2 confirmed · #3 confirmed
## Cycle 16
- verdicts: #101 no-effect · #102 regressed
## Cycle 17
- verdicts: #201 no-effect · #202 no-effect
FIX

cat > "$TMP/headless.txt" <<'FIX'
- verdicts: #101 no-effect · #102 regressed
- verdicts: #201 no-effect · #202 no-effect
FIX

# --- (1) no verdict lines at all -------------------------------------------
case_hdr "(1) zero verdict lines: nothing to decide on"
on "$TMP/prose.txt"
expect_rc "(1) prose-only comments exit 0" 0
expect_empty "(1) prose-only comments print nothing" "$OUT"

# --- (2) one verdict line: TWO are required --------------------------------
case_hdr "(2) one barren verdict line is not enough"
on "$TMP/one.txt"
expect_rc "(2) a single barren line exits 0" 0
expect_empty "(2) a single barren line prints nothing" "$OUT"

# --- (3) two barren lines: the switch fires --------------------------------
case_hdr "(3) two barren verdict lines fire the switch"
on "$TMP/two-barren.txt"
expect_rc "(3) two barren lines exit 3" 3
expect_eq "(3) the line names both cycles, older first" "$OUT" "DIMINISHING cycles=16,17"

# --- (4)/(5) one `confirmed` anywhere in the window holds it off -----------
case_hdr "(4) the NEWEST line carries confirmed"
on "$TMP/newest-confirmed.txt"
expect_rc "(4) a confirmed newest line exits 0" 0
expect_empty "(4) a confirmed newest line prints nothing" "$OUT"

case_hdr "(5) the OLDEST line carries confirmed"
on "$TMP/oldest-confirmed.txt"
expect_rc "(5) a confirmed oldest line exits 0" 0
expect_empty "(5) a confirmed oldest line prints nothing" "$OUT"

# --- (6) the window is the LAST TWO, not the whole history -----------------
case_hdr "(6) four lines: only the last two are in the window"
on "$TMP/four.txt"
expect_rc "(6) an older confirmed does not hold the switch off" 3
expect_eq "(6) the window names the last two cycles" "$OUT" "DIMINISHING cycles=16,17"

# --- (7) the LABEL degrades, the DECISION does not -------------------------
case_hdr "(7) no ## Cycle heading above the verdict lines"
on "$TMP/headless.txt"
expect_rc "(7) an unlabelled pair still fires" 3
expect_eq "(7) the cycle label degrades to the sentinel" "$OUT" "DIMINISHING cycles=--,--"

# --- (8) FAIL-LOUD on argv, and NEVER with the reserved code ---------------
case_hdr "(8) usage error: no source of comments at all"
dimin
expect_rc "(8) neither --tracker nor --comments-file is a usage error" 1
refute_rc "(8) a usage error is never read as a DIMINISHING signal" 3
expect_nonempty "(8) the usage banner goes to stderr" "$ERR"

# --- (9) --help is a documented, zero-cost banner --------------------------
case_hdr "(9) --help: rc 0 and a banner"
dimin --help
expect_rc "(9) --help exits 0" 0
expect_nonempty "(9) --help prints a banner" "$OUT"

# --- (10) comment-trust control, at the SOURCE level -----------------------
# hooks/enforce-comment-trust.py DENIES `gh issue view --json comments`. The
# production read must therefore go through filter-trusted-comments.sh. This
# is mechanical (a grep over the script) rather than behavioural, because the
# denied call is exactly the one a test must never make.
case_hdr "(10) trust control: filter-trusted-comments.sh, never --json comments"
if [ -f "$SCRIPT" ]; then
  pass_msg "(10) the script exists (the mechanical control is not vacuous)"
else
  fail_msg "(10) the script exists (the mechanical control is not vacuous)"
fi
if grep -qF -- '--json comments' "$SCRIPT" 2>/dev/null; then
  fail_msg "(10) the script must NEVER fetch raw comments (--json comments found)"
else
  pass_msg "(10) the script never fetches raw comments"
fi
if grep -qF 'filter-trusted-comments.sh' "$SCRIPT" 2>/dev/null; then
  pass_msg "(10) the script reads through the trust filter of record"
else
  fail_msg "(10) the script must read through filter-trusted-comments.sh"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
