#!/bin/bash
set -uo pipefail
#
# Tests for scripts/run-retro.sh `verdict_candidates()` — the RETRO-WINS
# Measured-by matcher (issue #1293, tracker #1271).
#
# Today's predicate is a literal, case-sensitive substring test:
#   contains("Measured by: retro (next cycle)")
# so a cycle issue whose Measured-by line says the same thing in different
# words — or in different case, or alongside the calibration run — silently
# drops out of `verdict-candidates:`. The operator then never gets asked for
# the verdict the loop exists to record.
#
# The contract this file pins:
#   A cycle issue is a verdict candidate when its `Measured by:` LINE names
#   `retro` in any case. Naming the calibration run TOO does not disqualify
#   it (retro wins); naming ONLY the calibration run does — that line carries
#   no `retro` token, so the same single predicate excludes it.
#
# Substrate: the shared tests/fixtures/run-retro/ tree copied to a temp dir,
# with the three cycle-0 issue bodies (#1272/#1273/#1274 per tracker.md)
# rewritten. The shared fixture dir is NEVER mutated — tests/test-run-retro.sh
# Scenario 15 asserts the UNMODIFIED bodies, and the calib-ingest test states
# the copy-before-mutate rule.
#
# BEHAVIOUR TEST ONLY — nothing here greps SKILL.md / CLAUDE.md prose.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/run-retro.sh"
FIXTURE_SRC="$ROOT/tests/fixtures/run-retro"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIX="$TMP/fixture"
cp -r "$FIXTURE_SRC" "$FIX"

# The three rewritten Measured-by lines. Each is one half of the contract:
#   #1272 — calibration-ONLY: the exclusion control. No `retro` token.
#   #1273 — loosened phrasing AND case variance in a single body.
#   #1274 — the HYBRID line, copied from live #1291: calibration run AND
#           retro. Retro wins, so this issue IS a candidate.
M1272='- Measured by: calibration run (--profile lean --model opus vs run #2 strict).'
M1273='- Measured By: Cycle-3 Retro (run-retro.sh --cycle 3) — zero friction lines.'
M1274='- Measured by: calibration run (--profile lean --model opus vs run #2 strict) and retro (next cycle) over agent-costs per-issue rows.'

jq --arg m1272 "$M1272" --arg m1273 "$M1273" --arg m1274 "$M1274" '
  map(
    ( if   .number == 1272 then $m1272
      elif .number == 1273 then $m1273
      elif .number == 1274 then $m1274
      else null end ) as $m
    | if $m == null then .
      else .body = ((.body // "")
                     | split("\n")
                     | map(if test("^- Measured [Bb]y:") then $m else . end)
                     | join("\n"))
      end
  )
' "$FIXTURE_SRC/issues.json" > "$FIX/issues.json"

# Guard the substrate itself: if the rewrite silently no-ops, every assertion
# below would pin the ORIGINAL bodies and prove nothing.
scenario "Scenario 0: the temp fixture really carries the rewritten bodies"
REWROTE_OK=1
for pair in "1272:$M1272" "1273:$M1273" "1274:$M1274"; do
  n="${pair%%:*}"; want="${pair#*:}"
  got="$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' "$FIX/issues.json" \
         | grep -i '^- Measured By:')"
  if [ "$got" != "$want" ]; then
    REWROTE_OK=0
    echo "    #$n body line is: $got"
  fi
done
if [ "$REWROTE_OK" -eq 1 ]; then
  pass_msg "all three cycle-0 Measured-by lines were rewritten in the temp copy"
else
  fail_msg "the jq body rewrite did not take — every assertion below is vacuous"
fi
if grep -qF 'Measured by: retro (next cycle)' <(jq -r '.[] | select(.number == 1272 or .number == 1273 or .number == 1274) | .body' "$FIX/issues.json"); then
  fail_msg "a cycle-0 body still carries the literal today's predicate matches — the test would pass for the wrong reason"
else
  pass_msg "no cycle-0 body carries the literal 'Measured by: retro (next cycle)'"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 1: retro wins — loosened phrasing, case variance, hybrid line"
# ---------------------------------------------------------------------------
POST_OUT="$(bash "$HELPER" --cycle 0 --post --fixture "$FIX" 2>/dev/null)"
CAND="$(printf '%s\n' "$POST_OUT" | grep -F 'verdict-candidates:' | head -1)"

# NON-VACUITY FIRST. Every assertion after this one is a claim about which
# issues the line names; if the line is empty (or absent) they would all pass
# or fail for reasons unrelated to the matcher.
if printf '%s' "$CAND" | grep -qE 'verdict-candidates:[[:space:]]+[0-9]'; then
  pass_msg "verdict-candidates: names at least one issue (line: $CAND)"
else
  fail_msg "verdict-candidates: names no issue at all (line: $CAND)"
fi

if printf '%s' "$CAND" | grep -qw '1273'; then
  pass_msg "#1273 is a candidate — 'Measured By: Cycle-3 Retro' matches case-insensitively and without the canonical phrasing"
else
  fail_msg "#1273 missing from verdict candidates (line: $CAND)"
fi

if printf '%s' "$CAND" | grep -qw '1274'; then
  pass_msg "#1274 is a candidate — the hybrid 'calibration run … and retro (next cycle)' line still names retro, so retro wins"
else
  fail_msg "#1274 missing from verdict candidates — a calibration-run clause must not veto a line that also names retro (line: $CAND)"
fi

if printf '%s' "$CAND" | grep -qw '1272'; then
  fail_msg "#1272 wrongly included — its Measured-by line names ONLY the calibration run (line: $CAND)"
else
  pass_msg "#1272 excluded — a calibration-ONLY Measured-by line carries no retro token"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 2: the matcher stays inside the Measured-by LINE"
# ---------------------------------------------------------------------------
# `.` does not cross newlines without the `s` flag, so a calibration-only
# Measured-by line followed LATER in the body by the word `retro` must still
# be excluded. #1272 already carries `run-retro.sh` nowhere, so plant it.
FIX2="$TMP/fixture-linescope"
cp -r "$FIXTURE_SRC" "$FIX2"
jq --arg m1272 "$M1272" --arg m1273 "$M1273" --arg m1274 "$M1274" '
  map(
    ( if   .number == 1272 then ($m1272 + "\n- Follow-up: the retro will echo this row.")
      elif .number == 1273 then $m1273
      elif .number == 1274 then $m1274
      else null end ) as $m
    | if $m == null then .
      else .body = ((.body // "")
                     | split("\n")
                     | map(if test("^- Measured [Bb]y:") then $m else . end)
                     | join("\n"))
      end
  )
' "$FIXTURE_SRC/issues.json" > "$FIX2/issues.json"

CAND2="$(bash "$HELPER" --cycle 0 --post --fixture "$FIX2" 2>/dev/null \
         | grep -F 'verdict-candidates:' | head -1)"
if printf '%s' "$CAND2" | grep -qE 'verdict-candidates:[[:space:]]+[0-9]'; then
  pass_msg "line-scope control: verdict-candidates: names at least one issue (line: $CAND2)"
else
  fail_msg "line-scope control: verdict-candidates: names no issue at all (line: $CAND2)"
fi
if printf '%s' "$CAND2" | grep -qw '1272'; then
  fail_msg "#1272 wrongly included — 'retro' appears on a LATER body line, not on the Measured-by line (line: $CAND2)"
else
  pass_msg "#1272 still excluded — the match cannot leak across newlines into a later body line"
fi

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
