#!/bin/bash
set -euo pipefail

# Guard: skills/create-issues/SKILL.md must document the Option B auto-accept
# behaviour (issue #767, default-on, per the `## Direction chosen` comment).
#
# Design (Option B, default-on):
#   - Auto-skip the confirm gate ONLY when BOTH hold: scope-check produced
#     exactly 1 issue (no split) AND grouping-check returned REC=STANDALONE.
#   - Any split (N>=2) / TRACKER / GROUP keeps the existing confirm gate.
#   - A `--confirm` argv flag forces the gate even on the single-standalone path.
#   - On auto-skip, print a one-line notice
#     `Auto-creating (single standalone, no confirm gate — pass --confirm to gate)`
#     then create; body is NOT re-rendered.
#   - No config flag (deliberately — avoids growing the PIPELINE_* surface).
#
# Asserts the skill PROSE encodes:
#   (a) the both-conditions auto-skip predicate (1 issue AND REC=STANDALONE)
#   (b) `--confirm` argv forcing the gate on the single-standalone path
#   (c) the gate still firing on split / tracker / group
#   (d) the one-line auto-create notice string
#   (e) the prose explicitly states NO config flag was introduced (Option C
#       rejected). Note: this test deliberately does NOT spell out the
#       rejected `PIPELINE_*` flag name as a literal token — check-config-drift.sh
#       scans tests/ for `PIPELINE_*` references, so naming it here (or in the
#       skill) would register a phantom undeclared-config reference.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_PATH="$SCRIPT_DIR/../skills/create-issues/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_PATH" ]; then
  echo "  FAIL: SKILL.md not found at $SKILL_PATH"
  exit 1
fi

# (a) Both-conditions auto-skip predicate: exactly 1 issue AND REC=STANDALONE.
inc
if grep -qiE 'exactly (one|1) (issue|standalone)' "$SKILL_PATH" \
   && grep -qF 'REC=STANDALONE' "$SKILL_PATH"; then
  pass_msg "documents the both-conditions auto-skip predicate (1 issue AND REC=STANDALONE)"
else
  fail_msg "missing the both-conditions auto-skip predicate (1 issue AND REC=STANDALONE)"
fi

# (b) `--confirm` argv forces the gate even on the single-standalone path.
inc
if grep -qF -- '--confirm' "$SKILL_PATH"; then
  pass_msg "documents the --confirm override forcing the gate"
else
  fail_msg "missing the --confirm override"
fi

# (c) The gate still fires on split / tracker / group.
inc
if grep -qiE 'split.*(tracker|group)|(tracker|group).*split' "$SKILL_PATH" \
   && grep -qiE 'keep[s]? the (confirm )?gate|gate (stays|remains|still)' "$SKILL_PATH"; then
  pass_msg "documents the gate still firing on split / tracker / group"
else
  fail_msg "missing the 'gate still fires on split/tracker/group' invariant"
fi

# (d) The exact one-line auto-create notice string.
inc
if grep -qF 'Auto-creating (single standalone, no confirm gate — pass --confirm to gate)' "$SKILL_PATH"; then
  pass_msg "carries the verbatim auto-create notice line"
else
  fail_msg "missing the verbatim 'Auto-creating (single standalone ...)' notice line"
fi

# (e) No config flag for this behaviour (Option C was rejected). Asserted via
# the positive prose, and by ensuring no PIPELINE_*AUTO_ACCEPT token leaks in
# (which would register a phantom undeclared-config reference in
# check-config-drift.sh, which scans skills/).
inc
if grep -qiE 'no config (flag|key)' "$SKILL_PATH" \
   && ! grep -qE 'PIPELINE_[A-Z0-9_]*AUTO_ACCEPT' "$SKILL_PATH"; then
  pass_msg "documents 'no config flag' and leaks no PIPELINE_*AUTO_ACCEPT token"
else
  fail_msg "missing the 'no config flag' prose, or leaks a PIPELINE_*AUTO_ACCEPT token"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
