#!/bin/bash
set -uo pipefail
#
# Tests for skills/evolve/SKILL.md — the /pipeline:evolve harness-evolve loop
# driver (issue #1273).
#
# The evolve skill is loaded into an attended orchestrator session that then
# runs full cycles (observe -> diagnose -> file -> fullsend -> measure ->
# decide -> log) back to back. Every token the skill body spends is paid on
# EVERY cycle boundary and competes with the loop's own working context, so
# the body carries a hard budget: <=3000 tokens (words x 1.35), with a
# non-vacuity floor so an empty/stub body cannot pass the ceiling trivially.
#
# Frontmatter assertions are parsed from the FIRST `---` block only and the
# budget is measured against the BODY (frontmatter stripped) via
# tests/_lib/skill-body.sh — a whole-file grep is satisfiable by the
# `description:` line alone (#1218).
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tests/_lib/skill-body.sh
source "$SCRIPT_DIR/_lib/skill-body.sh"

SKILL="$REPO_ROOT/skills/evolve/SKILL.md"
BUDGET_TOKENS=3000
MIN_WORDS=300

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

# --- Scenario 1: the skill exists ---
inc_scenario "Scenario 1: skills/evolve/SKILL.md exists"

if [ -f "$SKILL" ]; then
  pass_msg "skills/evolve/SKILL.md exists"
else
  fail_msg "skills/evolve/SKILL.md missing"
fi

# --- Scenario 2: frontmatter contract (FIRST --- block only) ---
inc_scenario "Scenario 2: frontmatter contract"

FM=$(awk 'NR==1&&$0=="---"{fm=1;next} fm&&$0=="---"{exit} fm' "$SKILL" 2>/dev/null)

if grep -qE '^name:[[:space:]]*evolve$' <<<"$FM"; then
  pass_msg "frontmatter declares name: evolve"
else
  fail_msg "frontmatter does not declare 'name: evolve'"
fi

DESC=$(grep -E '^description:' <<<"$FM")
for token in start stop pause resume status "/pipeline:evolve"; do
  if grep -qF -- "$token" <<<"$DESC"; then
    pass_msg "description advertises \"$token\""
  else
    fail_msg "description does not advertise \"$token\""
  fi
done

TOOLS=$(grep -E '^allowed-tools:' <<<"$FM")
for tool in Bash Skill; do
  if grep -qF -- "$tool" <<<"$TOOLS"; then
    pass_msg "allowed-tools grants $tool"
  else
    fail_msg "allowed-tools does not grant $tool (needed to drive the loop)"
  fi
done

# --- Scenario 3: body token budget (and non-vacuity floor) ---
inc_scenario "Scenario 3: body token budget"

WORDS=$(skill_body "$SKILL" 2>/dev/null | wc -w)
TOKENS=$(( WORDS * 135 / 100 ))
echo "evolve body: words=$WORDS tokens≈$TOKENS budget=$BUDGET_TOKENS"

if [ "$TOKENS" -le "$BUDGET_TOKENS" ]; then
  pass_msg "body is within budget (tokens≈$TOKENS <= $BUDGET_TOKENS)"
else
  fail_msg "body EXCEEDS budget (tokens≈$TOKENS > $BUDGET_TOKENS) — trim, never raise the ceiling"
fi

if [ "$WORDS" -ge "$MIN_WORDS" ]; then
  pass_msg "body is non-vacuous (words=$WORDS >= $MIN_WORDS)"
else
  fail_msg "body is vacuous (words=$WORDS < $MIN_WORDS) — a stub must not pass the ceiling"
fi

# --- Summary ---
echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
