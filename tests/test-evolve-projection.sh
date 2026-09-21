#!/usr/bin/env bash
# Unit guard for scripts/evolve-projection.sh (#1287).
#
# The `## Usage gate + projection` fence in skills/evolve/SKILL.md carried four
# awk field references (`$0`, `f[…]` fed by `split($0,…)`). The harness rewrites
# `$0`-`$9` when it loads a skill body, so those lines can never reach Bash
# intact — cycle-1 observed `awk '{sub(/\r$/,"",1281)}'` in the sibling pr-eval
# fence. The projection therefore moves into a script, which the harness never
# rewrites, and the fence keeps only `sed -nE` with `\1` backreferences.
#
# Contract under test (one line, always):
#   PROJECTION decision=<tok> est5=<n> est7=<n> five=<n|--> seven=<n|--> resume_at=<ISO8601|-->
# EST5/EST7 = median of the last three NON-NEGATIVE per-cycle deltas parsed out
# of the tracker's trusted `- usage:` comments; defaults 30 / 8 (spec §5).
# Exit 0 ALWAYS (fail-open — a gate helper that aborts wedges the evolve loop).
#
# Two test seams keep this hermetic: `--comments-file` (local usage lines, no
# gh/network) and `--now` (deterministic resume_at, mirroring usage-gate.sh:72).
# `--comments-file` is TEST-ONLY: `--tracker` stays the sole production route
# and always goes through filter-trusted-comments.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

# `ROOT="$(pwd)"` — the line above already cd-ed. NO existence guard: a missing
# script must surface as the genuine interpreter failure (exit 127).
ROOT="$(pwd)"
SCRIPT="$ROOT/scripts/evolve-projection.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NOW="2026-01-01T00:00:00Z"
RESUME5="2026-01-01T05:00:00Z"
# A gate line that can never flip the decision, so cases (1)-(5) isolate the
# median arithmetic: decision is not `proceed` and both percentages are `--`.
SKIP_GATE="usage-gate: decision=skip reason=disabled five_hour=-- seven_day=-- threshold=85 resume_at=--"
# The grammar the evolve fence's `sed -nE` parses back out. Verbatim, single
# alternation, fully anchored.
GRAMMAR='^PROJECTION decision=[a-z0-9-]+ est5=[0-9]+ est7=[0-9]+ five=([0-9]+|--) seven=([0-9]+|--) resume_at=([0-9T:Z-]+|--)$'

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# field <line> <key> — exact-token lookup, so `seven=` never matches `est7=`.
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -nE "s/^$2=(.*)$/\1/p"; }

# assert_field <label> <line> <key> <want>
assert_field() {
  local got; got="$(field "$2" "$3")"
  if [ "$got" = "$4" ]; then
    pass_msg "$1: $3=$4"
  else
    fail_msg "$1: want $3=$4, got $3=${got:-<empty>} (line: $2)"
  fi
}

# proj <comments-file> <gate-line> — run the script hermetically.
proj() { bash "$SCRIPT" --comments-file "$1" --gate-line "$2" --now "$NOW"; }

# --- fixtures -------------------------------------------------------------
# `- usage: start five_hour=<a> seven_day=<b> end five_hour=<c> seven_day=<d>`
# (skills/evolve/SKILL.md `## Cycle comment`) => d5 = c-a, d7 = d-b.

: > "$TMP/none.txt"
printf '%s\n' "## Cycle 3" "- issues: #1 #2" "- retro: docs/retros/cycle-03.md" > "$TMP/prose.txt"

cat > "$TMP/three.txt" <<'FIX'
Prose that is not a usage line at all.
- usage: start five_hour=10 seven_day=20 end five_hour=40 seven_day=28
- usage: start five_hour=0 seven_day=0 end five_hour=10 seven_day=2
- usage: start five_hour=5 seven_day=5 end five_hour=25 seven_day=11
FIX

cat > "$TMP/negative.txt" <<'FIX'
- usage: start five_hour=10 seven_day=20 end five_hour=20 seven_day=22
- usage: start five_hour=50 seven_day=50 end five_hour=45 seven_day=53
- usage: start five_hour=0 seven_day=0 end five_hour=20 seven_day=6
FIX

cat > "$TMP/five.txt" <<'FIX'
- usage: start five_hour=0 seven_day=0 end five_hour=100 seven_day=50
- usage: start five_hour=0 seven_day=0 end five_hour=200 seven_day=60
- usage: start five_hour=0 seven_day=0 end five_hour=10 seven_day=2
- usage: start five_hour=0 seven_day=0 end five_hour=20 seven_day=6
- usage: start five_hour=0 seven_day=0 end five_hour=30 seven_day=8
FIX

cat > "$TMP/even.txt" <<'FIX'
- usage: start five_hour=0 seven_day=0 end five_hour=10 seven_day=2
- usage: start five_hour=0 seven_day=0 end five_hour=25 seven_day=7
FIX

cat > "$TMP/one.txt" <<'FIX'
- usage: start five_hour=1 seven_day=1 end five_hour=3 seven_day=2
FIX

# --- (1) three usage lines => EST5/EST7 are the medians of the deltas -------
# deltas: (30,8) (10,2) (20,6) => est5 = median(10,20,30) = 20
#                                 est7 = median(2,6,8)    = 6
OUT1="$(proj "$TMP/three.txt" "$SKIP_GATE")"
assert_field "(1) medians of three cycles" "$OUT1" est5 20
assert_field "(1) medians of three cycles" "$OUT1" est7 6

# --- (2) a delta negative on EITHER axis is EXCLUDED ------------------------
# rows: (10,2) (-5,3 -> dropped on the five-hour axis) (20,6)
# kept  => even count => est5 = int((10+20+1)/2) = 15, est7 = int((2+6+1)/2) = 4
# if the row were NOT dropped the medians would be 10 / 3, so this discriminates.
OUT2="$(proj "$TMP/negative.txt" "$SKIP_GATE")"
assert_field "(2) negative-delta row excluded" "$OUT2" est5 15
assert_field "(2) negative-delta row excluded" "$OUT2" est7 4

# --- (3) no usage lines => the spec defaults --------------------------------
OUT3="$(proj "$TMP/prose.txt" "$SKIP_GATE")"
assert_field "(3) no usage lines => default" "$OUT3" est5 30
assert_field "(3) no usage lines => default" "$OUT3" est7 8
OUT3B="$(proj "$TMP/none.txt" "$SKIP_GATE")"
assert_field "(3) empty comments file => default" "$OUT3B" est5 30
assert_field "(3) empty comments file => default" "$OUT3B" est7 8

# --- (4) more than three usable rows => only the LAST three count -----------
# last three: (10,2) (20,6) (30,8) => 20 / 6. All five would give 30 / 8.
OUT4="$(proj "$TMP/five.txt" "$SKIP_GATE")"
assert_field "(4) only the last three rows count" "$OUT4" est5 20
assert_field "(4) only the last three rows count" "$OUT4" est7 6

# --- (5) even count => round-half-up mean of the two middles ----------------
# (10,2) (25,7) => est5 = int((10+25+1)/2) = 18 (a plain floor would give 17)
#                  est7 = int((2+7+1)/2)   = 5  (a plain floor would give 4)
OUT5="$(proj "$TMP/even.txt" "$SKIP_GATE")"
assert_field "(5) even count rounds half up" "$OUT5" est5 18
assert_field "(5) even count rounds half up" "$OUT5" est7 5

# --- (6) projection flips a `proceed` gate to pause-5h ----------------------
# defaults est5=30; five=70 => 70+30 = 100 > 85 => pause-5h, resume_at = now+5h.
GATE6="usage-gate: decision=proceed five_hour=70% seven_day=10% threshold=85 resume_at=--"
OUT6="$(proj "$TMP/none.txt" "$GATE6")"
assert_field "(6) proceed flips to pause-5h" "$OUT6" decision pause-5h
assert_field "(6) proceed flips to pause-5h" "$OUT6" five 70
assert_field "(6) proceed flips to pause-5h" "$OUT6" seven 10
assert_field "(6) resume_at is --now + 5h" "$OUT6" resume_at "$RESUME5"

# --- (7) a non-proceed decision passes through untouched --------------------
GATE7="usage-gate: decision=halt-7d five_hour=99% seven_day=97% threshold=85 resume_at=2026-01-08T00:00:00Z"
OUT7="$(proj "$TMP/none.txt" "$GATE7")"
assert_field "(7) halt-7d passes through" "$OUT7" decision halt-7d
assert_field "(7) halt-7d passes through" "$OUT7" five 99
assert_field "(7) halt-7d passes through" "$OUT7" seven 97
assert_field "(7) halt-7d keeps its resume_at" "$OUT7" resume_at "2026-01-08T00:00:00Z"

# --- (8) output grammar: EXACTLY one line, anchored -------------------------
for probe in "6:$OUT6" "7:$OUT7" "1:$OUT1"; do
  label="${probe%%:*}"; line="${probe#*:}"
  n="$(printf '%s\n' "$line" | grep -c .)"
  if [ "$n" = "1" ]; then
    pass_msg "(8) case ($label) emits exactly one line"
  else
    fail_msg "(8) case ($label) emitted $n lines, expected 1"
  fi
  if printf '%s\n' "$line" | grep -qE "$GRAMMAR"; then
    pass_msg "(8) case ($label) matches the PROJECTION grammar"
  else
    fail_msg "(8) case ($label) does not match the PROJECTION grammar: $line"
  fi
done
# Negative control: the anchor must reject a trailing token, else (8) is vacuous.
if printf '%s\n' "PROJECTION decision=proceed est5=30 est7=8 five=70 seven=10 resume_at=-- extra=1" \
  | grep -qE "$GRAMMAR"; then
  fail_msg "(8) negative control: the grammar is not anchored — trailing garbage matched"
else
  pass_msg "(8) negative control: trailing garbage is rejected by the anchored grammar"
fi

# --- (9) decimal percentage: integer part only ------------------------------
# usage-gate.sh emits `five_hour=<N%|-->` where N may be decimal. The replaced
# fence captured `([0-9]+)(\.[0-9]+)?%` group 1 ONLY, so `84.5%` => 84 and the
# `$((FIVE+EST5))` arithmetic never sees a non-integer. one.txt => est5=2, so
# 84+2 = 86 > 85 and the decision flips — the flip firing at all is the proof
# that the fraction was stripped before the arithmetic.
GATE9="usage-gate: decision=proceed five_hour=84.5% seven_day=10% threshold=85 resume_at=--"
OUT9="$(proj "$TMP/one.txt" "$GATE9")"
assert_field "(9) decimal percentage keeps the integer part" "$OUT9" five 84
assert_field "(9) decimal percentage still projects" "$OUT9" est5 2
assert_field "(9) decimal percentage still projects" "$OUT9" decision pause-5h
assert_field "(9) decimal percentage still projects" "$OUT9" resume_at "$RESUME5"

# --- (10) the `--` sentinel round-trips verbatim ----------------------------
OUT10="$(proj "$TMP/none.txt" "$SKIP_GATE")"
assert_field "(10) -- sentinel round-trip" "$OUT10" five "--"
assert_field "(10) -- sentinel round-trip" "$OUT10" seven "--"
assert_field "(10) -- sentinel round-trip" "$OUT10" resume_at "--"
assert_field "(10) -- sentinel leaves the decision alone" "$OUT10" decision skip
if printf '%s\n' "$OUT10" | grep -qE "$GRAMMAR"; then
  pass_msg "(10) the all-sentinel line still satisfies the grammar"
else
  fail_msg "(10) the all-sentinel line breaks the grammar: $OUT10"
fi

# --- (11) FAIL-OPEN: exit 0 even when the comment read fails ----------------
# Asserted LAST and with an explicit status capture — every case above relies
# on `set -e` aborting on a non-zero status, which is why a missing script reds
# this file at 127.
rc=0
OUT11="$(bash "$SCRIPT" --comments-file "$TMP/does-not-exist.txt" --gate-line "$SKIP_GATE" --now "$NOW")" || rc=$?
if [ "$rc" = "0" ]; then
  pass_msg "(11) fail-open: exit 0 when the comment read fails"
else
  fail_msg "(11) must exit 0 when the comment read fails (fail-open); got rc=$rc"
fi
if printf '%s\n' "$OUT11" | grep -qE "$GRAMMAR"; then
  pass_msg "(11) a failed read still emits a well-formed PROJECTION line"
else
  fail_msg "(11) a failed read did not emit a well-formed PROJECTION line: $OUT11"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
