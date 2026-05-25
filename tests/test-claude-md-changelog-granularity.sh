#!/bin/bash
set -uo pipefail
# Per #492: pins the per-PR CHANGELOG granularity contract phrasing in CLAUDE.md.
#
# DELIBERATE doubled brittle assertion — this test couples to TWO literal phrases:
#   (a) `merge-commit subject`             and
#   (b) `one entry per merged feature PR`
# Any future paraphrase of EITHER phrase breaks this test on purpose: both phrases
# ARE the contract. A copy-edit that loses either is a doctrine drift, not a
# cosmetic change. See docs/release-cadence.md#granularity-scope-decision-492.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$CLAUDE_MD" ]; then
  fail_msg "CLAUDE.md exists at repo root"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

if grep -qF 'merge-commit subject' "$CLAUDE_MD"; then
  pass_msg "CLAUDE.md contains literal phrase 'merge-commit subject'"
else
  fail_msg "CLAUDE.md contains literal phrase 'merge-commit subject'"
fi

if grep -qF 'one entry per merged feature PR' "$CLAUDE_MD"; then
  pass_msg "CLAUDE.md contains literal phrase 'one entry per merged feature PR'"
else
  fail_msg "CLAUDE.md contains literal phrase 'one entry per merged feature PR'"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
