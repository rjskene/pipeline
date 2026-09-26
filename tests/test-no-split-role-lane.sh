#!/usr/bin/env bash
set -uo pipefail

# Absence guard for the retired split-role TDD lane — scripts/ + config surface
# (issue #1420, Task 1).
#
# #881 Phase 2 shipped a two-agent PATH B execute: an Opus test-author committed
# the locked failing suite with `[split-role-red]` in the subject, then a cheaper
# implementer greened it additive-only under an eval-time git invariant
# (scripts/split-role-gate.sh). Calibration runs #11-#13 measured NO cost or
# latency return for that redundancy, so #1420 collapses PATH B back to ONE
# execute agent and deletes the whole lane: the gate, its shared-tests parser,
# the resolver's shape emission, the --verify-dispatch shape scan, and the two
# knobs only that lane read (the #881 PATH B shape flag and the #1201
# discoverable-test basename globs).
#
# NEEDLE CONSTRUCTION — every retired knob name below is assembled at runtime from
# $KP + a suffix, NEVER written as one literal token. scripts/check-config-drift.sh
# scans tests/ for `\bPIPELINE_[A-Z0-9_]+\b` and reports any extracted token with no
# pipeline.config.example declaration as UNDOCUMENTED. A negative guard spelling a
# retired knob literally therefore RE-REFERENCES the very knob it is proving gone,
# pinning it UNDOCUMENTED forever — this file would have made the tree permanently
# drift-dirty. Splitting the prefix makes the assertion just as exact while leaving
# the scan nothing to extract. (The alternative, an allow-list exemption per knob,
# is reserved for knobs a LIVE test genuinely still sets — see assertion (6).)
#
# This guard is the mechanical backstop against the lane creeping back in under
# scripts/ or the tracked config surface. The ONLY sanctioned survivors are the
# three cost-attribution readers: the historical `role=red|green` rows in
# .claude/logs/agent-costs.jsonl must keep pricing, so the parsers stay tolerant
# of them (per the plan's cost-attribution-tolerant-of-history decision).
#
# Static filesystem/grep scan over named paths only — no `gh`, no network, no
# dispatch. The skills/ and docs/ surfaces are covered by the sibling guards
# tests/test-no-split-role-lane-skills.sh and
# tests/test-no-split-role-lane-docs.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Knob-name prefix, held apart from every suffix below. See NEEDLE CONSTRUCTION.
KP="PIPELINE_"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

echo "== test-no-split-role-lane (issue #1420) =="

# ---------------------------------------------------------------------------
# (1) The gate and its shared-tests parser are GONE from the tree.
# ---------------------------------------------------------------------------
for rel in scripts/split-role-gate.sh scripts/parse-shared-tests.sh; do
  inc
  if [ ! -e "$ROOT/$rel" ]; then
    pass_msg "(1) $rel is absent"
  else
    fail_msg "(1) $rel still exists"
  fi
done

# ---------------------------------------------------------------------------
# (2) Under scripts/, the ONLY files naming split-role are the three
#     cost-attribution readers that must keep pricing historical
#     role=red|green rows. An EXACT set: a new name here is a regression, and a
#     missing name means an attribution parser lost its history tolerance.
# ---------------------------------------------------------------------------
inc
ATTRIBUTION_ALLOWED="scripts/_token-usage-lib.sh scripts/capture-agent-costs.sh scripts/cost-latency-report.sh"
GOT_FILES="$(cd "$ROOT" && grep -rliE 'split[-_ ]role' scripts/ 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$GOT_FILES" = "$ATTRIBUTION_ALLOWED" ]; then
  pass_msg "(2) scripts/ names split-role only in the three attribution readers"
else
  fail_msg "(2) scripts/ split-role hits are '$GOT_FILES' (want exactly '$ATTRIBUTION_ALLOWED')"
fi

# ---------------------------------------------------------------------------
# (3) Both retired knobs are gone from pipeline.config.example. The knob
#     surface is the operator-facing contract: leaving a documented knob whose
#     only reader was deleted is exactly the inert-knob drift check-config-drift.sh
#     reports as ORPHAN.
# ---------------------------------------------------------------------------
EXAMPLE="$ROOT/pipeline.config.example"
for knob in "${KP}PATH_B_SPLIT_ROLE" "${KP}TEST_FILE_GLOBS"; do
  inc
  if [ ! -f "$EXAMPLE" ]; then
    fail_msg "(3) pipeline.config.example not found at $EXAMPLE"
  elif ! grep -qF "$knob" "$EXAMPLE"; then
    pass_msg "(3) pipeline.config.example no longer names $knob"
  else
    fail_msg "(3) pipeline.config.example still names $knob"
  fi
done

# ---------------------------------------------------------------------------
# (4) The eval-caller-set-only exemption for the gate's shared-tests knob is
#     peeled from the drift allow-list — the knob has no caller left to set it.
# ---------------------------------------------------------------------------
inc
ALLOWLIST="$ROOT/tests/config-drift-allowlist.txt"
SHARED_TESTS_KNOB="${KP}SPLIT_ROLE_SHARED_TESTS"
if [ ! -f "$ALLOWLIST" ]; then
  fail_msg "(4) tests/config-drift-allowlist.txt not found at $ALLOWLIST"
elif ! grep -qF "$SHARED_TESTS_KNOB" "$ALLOWLIST"; then
  pass_msg "(4) config-drift-allowlist.txt no longer carries $SHARED_TESTS_KNOB"
else
  fail_msg "(4) config-drift-allowlist.txt still carries $SHARED_TESTS_KNOB"
fi

# ---------------------------------------------------------------------------
# (5) --verify-dispatch is a pure MODEL check: the shape half of the contract
#     (and its VED_EXPECT_SPLIT_ROLE input) is gone. A surviving read would
#     re-introduce the `shape:single!=split-role` mismatch verdict against a
#     resolver that can no longer ask for a split.
# ---------------------------------------------------------------------------
inc
VEC="$ROOT/scripts/verify-execute-completion.sh"
if [ ! -f "$VEC" ]; then
  fail_msg "(5) scripts/verify-execute-completion.sh not found at $VEC"
elif ! grep -qF 'VED_EXPECT_SPLIT_ROLE' "$VEC"; then
  pass_msg "(5) verify-execute-completion.sh reads no VED_EXPECT_SPLIT_ROLE"
else
  fail_msg "(5) verify-execute-completion.sh still reads VED_EXPECT_SPLIT_ROLE"
fi

# ---------------------------------------------------------------------------
# (6) The #881 shape knob is the ONE retired knob a LIVE test still spells out:
#     tests/test-resolve-execute-dispatch.sh writes it into fixture configs to
#     prove the resolver IGNORES it (the ignored-knob cases). That literal is
#     load-bearing — a needle-splitting dodge there would stop the fixture from
#     actually setting the knob — so it stays, and check-config-drift.sh sees the
#     knob as referenced-but-undeclared. The documented remedy for exactly this
#     retired-knob-kept-alive-by-negative-guards class is a drift-allow-list
#     exact-match entry (the PIPELINE_CALIB_PROFILE precedent, #1291). Without it
#     the whole tree reads drift-dirty forever once every leaf lands.
#
#     This is the INVERSE of assertion (4): the shared-tests knob loses its entry
#     because nothing references it any more, while the shape knob GAINS one
#     because a deliberate negative guard still does.
# ---------------------------------------------------------------------------
inc
SHAPE_KNOB="${KP}PATH_B_SPLIT_ROLE"
if [ ! -f "$ALLOWLIST" ]; then
  fail_msg "(6) tests/config-drift-allowlist.txt not found at $ALLOWLIST"
elif grep -qxF "$SHAPE_KNOB" "$ALLOWLIST"; then
  pass_msg "(6) config-drift-allowlist.txt exact-match-exempts retired $SHAPE_KNOB"
else
  fail_msg "(6) config-drift-allowlist.txt has no exact-match entry for retired $SHAPE_KNOB (a live negative guard still sets it)"
fi

# (6b) Non-vacuity: the entry above is only justified while a live test really
#      does still set the knob. If that reference ever disappears, the exemption
#      must be peeled rather than left as permanent cover for a token nothing
#      names — the same hygiene that made assertion (4) removable.
inc
LIVE_REFS="$(cd "$ROOT" && grep -rlF "$SHAPE_KNOB" tests/ 2>/dev/null | grep -vxF 'tests/test-no-split-role-lane.sh' | grep -vxF 'tests/config-drift-allowlist.txt' || true)"
if [ -n "$LIVE_REFS" ]; then
  pass_msg "(6b) the exemption is still earned — live reference(s): $(printf '%s' "$LIVE_REFS" | tr '\n' ' ')"
else
  fail_msg "(6b) no live test references $SHAPE_KNOB any more — peel its allow-list entry"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
