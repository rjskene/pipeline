#!/bin/bash
set -uo pipefail

# Regression guard for issue #1508 — the execute dispatch contract must run the
# PROJECT's test command (`$PIPELINE_TEST_CMD`), never the plugin's own
# `scripts/run-test-suite.sh`.
#
# Pre-fix, the fullsend inline execute dispatch prompt contract and
# execute-issue-plan Step 6b both named
# `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/run-test-suite.sh" --chunk k/n` as the
# foreground runner. In a consumer repo that path is the PLUGIN's runner, not
# the project's test command. And Step 6b carried a bare
# `bash scripts/check-config-drift.sh` link that only resolves inside this repo;
# the consumer-root-aware drift check already runs once, via Step 9a's
# `check-cross-cutting-guards.sh`.
#
# Pins:
#   (a) fullsend contract paragraph names no `run-test-suite.sh` / `--chunk`.
#   (b) fullsend contract paragraph says Run `$PIPELINE_TEST_CMD` in the FOREGROUND.
#   (c) Step 6b names no plugin-root runner path.
#   (d) every Step 6b line naming `run-test-suite.sh` is the `Dogfood` note
#       (line-scoped, case-sensitive).
#   (e) Step 6b says Run `$PIPELINE_TEST_CMD` in the FOREGROUND.
#   (f) Step 6 carries no `&& bash scripts/check-config-drift.sh` link and no
#       `**6e.` heading.
#
# Mirrors the ROOT / pass_msg / fail_msg / inc / `exit 1` shape of
# tests/test-dispatch-no-background-test-run.sh; the region extractors are
# copied from it verbatim.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FULLSEND="skills/fullsend/SKILL.md"
EXECPLAN="skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$FULLSEND" "$EXECPLAN"; do
  if [ ! -f "$ROOT/$f" ]; then
    echo "FAIL: $f not found under $ROOT" >&2
    exit 1
  fi
done

contract_paragraph() {
  awk '
    /\*\*Inline execute dispatch prompt contract \(mandatory\)\.\*\*/ { inblock = 1; print; next }
    inblock && /^   \*\*/ { inblock = 0 }
    inblock { print }
  ' "$ROOT/skills/fullsend/SKILL.md"
}

step6b_region() {
  awk '
    /^\s*\*\*6b\. Run tests/ {capturing=1}
    /^\s*\*\*6c\./ {capturing=0}
    capturing {print}
  ' "$ROOT/skills/execute-issue-plan/SKILL.md"
}

step6_region() {
  awk '/^6\. \*\*Validate/{f=1} /^7\. \*\*Self-review/{f=0} f' "$ROOT/$EXECPLAN"
}

F_REGION="$(contract_paragraph)"
E_REGION="$(step6b_region)"
S6_REGION="$(step6_region)"

if [ -z "$F_REGION" ] || [ -z "$E_REGION" ] || [ -z "$S6_REGION" ]; then
  echo "FAIL: could not extract a region (fullsend contract / Step 6b / Step 6) — markers moved?" >&2
  exit 1
fi

F_FLAT="$(tr '\n' ' ' <<< "$F_REGION")"
E_FLAT="$(tr '\n' ' ' <<< "$E_REGION")"

FG_NEEDLE='Run `$PIPELINE_TEST_CMD` in the FOREGROUND'

# (a)
for needle in 'run-test-suite.sh' '--chunk'; do
  inc
  if grep -Fq -- "$needle" <<< "$F_FLAT"; then
    fail_msg "(a) fullsend contract paragraph names \"$needle\" — the dispatch contract must reference only \$PIPELINE_TEST_CMD"
  else
    pass_msg "(a) fullsend contract paragraph has no \"$needle\""
  fi
done

# (b)
inc
if grep -Fq -- "$FG_NEEDLE" <<< "$F_FLAT"; then
  pass_msg "(b) fullsend contract paragraph contains \"$FG_NEEDLE\""
else
  fail_msg "(b) fullsend contract paragraph missing \"$FG_NEEDLE\""
fi

# (c)
for needle in 'CLAUDE_PLUGIN_ROOT:-.}/scripts/run-test-suite.sh' 'CLAUDE_PLUGIN_ROOT}/scripts/run-test-suite.sh'; do
  inc
  if grep -Fq -- "$needle" <<< "$E_FLAT"; then
    fail_msg "(c) Step 6b names the plugin-root runner \"$needle\""
  else
    pass_msg "(c) Step 6b has no plugin-root runner \"$needle\""
  fi
done

# (d) line-scoped, case-sensitive.
inc
bad_lines="$(grep -F -- 'run-test-suite.sh' <<< "$E_REGION" | grep -vF -- 'Dogfood' || true)"
runner_lines="$(grep -cF -- 'run-test-suite.sh' <<< "$E_REGION" || true)"
if [ -n "$bad_lines" ]; then
  fail_msg "(d) Step 6b has a run-test-suite.sh line outside the \`Dogfood\` note"
else
  pass_msg "(d) every Step 6b run-test-suite.sh line carries the \`Dogfood\` label (${runner_lines:-0} line(s))"
fi

# (e)
inc
if grep -Fq -- "$FG_NEEDLE" <<< "$E_FLAT"; then
  pass_msg "(e) Step 6b contains \"$FG_NEEDLE\""
else
  fail_msg "(e) Step 6b missing \"$FG_NEEDLE\""
fi

# (f)
for needle in '&& bash scripts/check-config-drift.sh' '**6e.'; do
  inc
  if grep -Fq -- "$needle" <<< "$S6_REGION"; then
    fail_msg "(f) Step 6 still carries \"$needle\" — config drift runs once, via Step 9a check-cross-cutting-guards.sh"
  else
    pass_msg "(f) Step 6 has no \"$needle\""
  fi
done

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
