#!/bin/bash
set -euo pipefail
# Guard (#1420): the split-role RED/GREEN TDD lane is gone from the docs surface.
# PATH B dispatches ONE execute agent that applies the `tdd-implementer`
# discipline inline, so `docs/split-role-tdd.md`, `scripts/split-role-gate.sh`,
# `scripts/parse-shared-tests.sh`, the PATH B split-role shape knob and the
# `lean-single` resolver REASON no longer exist — no forward-looking doc may
# describe them as live behaviour.
#
# The knob name is assembled from KP + suffix rather than spelled literally:
# scripts/check-config-drift.sh extracts \bPIPELINE_[A-Z0-9_]+\b from tests/, so
# a literal here would re-reference a knob this issue deletes and pin it
# UNDOCUMENTED forever (same technique as tests/test-no-split-role-lane.sh and
# tests/test-no-split-role-lane-skills.sh). It also keeps assertion (6b) of
# tests/test-no-split-role-lane.sh honest: that assertion asserts the allow-list
# entry covers a LOAD-BEARING literal, and a second literal here would satisfy
# it vacuously.
#
# Exempt by contract: `docs/retros/`, `docs/tokenomics/` and `docs/superpowers/`
# are point-in-time historical records (retro transcripts, cost windows, design
# specs) and stay verbatim. A surviving `split-role` mention in the live docs is
# allowed ONLY as an explicit "removed by #1420" note, so the mention must sit on
# a line that also carries `#1420`.
#
# Companion guards: `tests/test-no-split-role-lane.sh` (scripts/ + config) and
# `tests/test-no-split-role-lane-skills.sh` (skills/).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

# Tokens that name the retired lane's machinery. A live doc naming any of these
# is making a claim about code that no longer exists.
KP="PIPELINE_"
RETIRED_TOKENS=(
  'split-role-tdd.md'
  'split-role-gate.sh'
  "${KP}PATH_B_SPLIT_ROLE"
  'lean-single'
  'parse-shared-tests.sh'
)

# The live docs that legitimately still mention the lane, as history.
HISTORY_DOCS=(
  'docs/cost-architecture.md'
  'docs/observability.md'
  'docs/calibration.md'
  'docs/analysis/model-downsampling.md'
  'docs/operational-notes.md'
)

echo "(1) docs/split-role-tdd.md is deleted"
inc
if [ -e "$ROOT/docs/split-role-tdd.md" ]; then
  fail_msg "docs/split-role-tdd.md still exists"
else
  pass_msg "docs/split-role-tdd.md is absent"
fi

echo ""
echo "(2) README.md names no split-role lane"
inc
if grep -niE 'split[-_ ]role' "$ROOT/README.md" >/dev/null 2>&1; then
  fail_msg "README.md still names split-role: $(grep -niE 'split[-_ ]role' "$ROOT/README.md" | head -3 | tr '\n' ' ')"
else
  pass_msg "README.md names no split-role"
fi

echo ""
echo "(3) no live doc references the retired machinery"
# Every file under docs/ except the historical archives.
mapfile -t live_docs < <(
  find "$ROOT/docs" -type f \
    -not -path "$ROOT/docs/retros/*" \
    -not -path "$ROOT/docs/tokenomics/*" \
    -not -path "$ROOT/docs/superpowers/*" \
    | sort
)
inc
if [ "${#live_docs[@]}" -ge 1 ]; then
  pass_msg "found ${#live_docs[@]} live docs to scan"
else
  fail_msg "found no live docs under docs/ — the scan would be vacuous"
fi

for token in "${RETIRED_TOKENS[@]}"; do
  hits=""
  for f in "${live_docs[@]}"; do
    if grep -qF -- "$token" "$f" 2>/dev/null; then
      hits="$hits ${f#$ROOT/}"
    fi
  done
  inc
  if [ -n "$hits" ]; then
    fail_msg "live docs still reference '$token':$hits"
  else
    pass_msg "no live doc references '$token'"
  fi
done

echo ""
echo "(4) surviving split-role mentions are labelled #1420"
for rel in "${HISTORY_DOCS[@]}"; do
  f="$ROOT/$rel"
  inc
  if [ ! -f "$f" ]; then
    fail_msg "$rel does not exist"
    continue
  fi
  bad="$(grep -niE 'split[-_ ]role' "$f" 2>/dev/null | grep -vF '#1420' || true)"
  if [ -n "$bad" ]; then
    fail_msg "$rel mentions split-role on a line without '#1420': $(printf '%s' "$bad" | head -3 | tr '\n' ' ')"
  else
    pass_msg "$rel: every split-role mention (if any) carries '#1420'"
  fi
done

echo ""
echo "(5) dev/calib/slate/README.md names no split-role routing shape"
inc
if grep -niE 'split[-_ ]role' "$ROOT/dev/calib/slate/README.md" >/dev/null 2>&1; then
  fail_msg "dev/calib/slate/README.md still names split-role: $(grep -niE 'split[-_ ]role' "$ROOT/dev/calib/slate/README.md" | head -3 | tr '\n' ' ')"
else
  pass_msg "dev/calib/slate/README.md names no split-role"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
