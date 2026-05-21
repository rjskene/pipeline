#!/bin/bash
set -uo pipefail

# Regression test for issue #325: classifier helper path resolution.
#
# Asserts that both run-queue.sh and spawn-claude.sh resolve the
# eval-classifier-invoke.sh helper from ${CLAUDE_PLUGIN_ROOT}/scripts/
# (the plugin install dir) and never from ${REPO_ROOT}/mock-web-eval/scripts/
# (the consumer-shipped dogfood location), that classify_issue() in
# run-queue.sh guards the helper invocation with a `[ -f ... ]` check
# (fail-OPEN), and that operator-facing prose no longer references the
# legacy mock-web-eval/scripts/eval-classifier-invoke.sh path. This is
# the same path-math family as #292 / #277 — the regression net keeps
# new code from drifting back into the consumer-relative resolution
# pattern that motivated the fix.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# -------------------------------------------------------------------------
# Test 1: run-queue.sh references ${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh
# -------------------------------------------------------------------------
echo "Test 1: run-queue.sh references \${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh"
inc
if grep -F '${CLAUDE_PLUGIN_ROOT:-.}/scripts/eval-classifier-invoke.sh' "$ROOT/scripts/run-queue.sh" > /dev/null; then
  pass_msg "run-queue.sh references \${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh"
else
  fail_msg "expected match, got 0 hits"
fi

# -------------------------------------------------------------------------
# Test 2: no ${REPO_ROOT}-rooted invocation remains in run-queue.sh
# -------------------------------------------------------------------------
echo "Test 2: no \${REPO_ROOT}-rooted invocation remains in run-queue.sh"
inc
_run_queue_hits=$(grep -cF '${REPO_ROOT}/mock-web-eval/scripts/eval-classifier-invoke.sh' "$ROOT/scripts/run-queue.sh" || true)
if [ "$_run_queue_hits" -eq 0 ]; then
  pass_msg "no \${REPO_ROOT}-rooted invocation remains in run-queue.sh"
else
  fail_msg "expected 0 hits, got $_run_queue_hits"
fi

# -------------------------------------------------------------------------
# Test 3: spawn-claude.sh references ${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh
# -------------------------------------------------------------------------
echo "Test 3: spawn-claude.sh references \${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh"
inc
if grep -F '${CLAUDE_PLUGIN_ROOT:-.}/scripts/eval-classifier-invoke.sh' "$ROOT/scripts/spawn-claude.sh" > /dev/null; then
  pass_msg "spawn-claude.sh references \${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh"
else
  fail_msg "expected match, got 0 hits"
fi

# -------------------------------------------------------------------------
# Test 4: no ${REPO_ROOT}-rooted _classifier_invoke assignment in spawn-claude.sh
# -------------------------------------------------------------------------
echo "Test 4: no \${REPO_ROOT}-rooted _classifier_invoke assignment in spawn-claude.sh"
inc
_spawn_claude_hits=$(grep -cF '${REPO_ROOT}/mock-web-eval/scripts/eval-classifier-invoke.sh' "$ROOT/scripts/spawn-claude.sh" || true)
if [ "$_spawn_claude_hits" -eq 0 ]; then
  pass_msg "no \${REPO_ROOT}-rooted _classifier_invoke assignment remains in spawn-claude.sh"
else
  fail_msg "expected 0 hits, got $_spawn_claude_hits"
fi

# -------------------------------------------------------------------------
# Test 5: classify_issue in run-queue.sh guards helper invocation with [ -f ... ]
# -------------------------------------------------------------------------
echo "Test 5: classify_issue in run-queue.sh guards helper invocation with [ -f ... ]"
inc
if awk '/^classify_issue\(\)/,/^}/' "$ROOT/scripts/run-queue.sh" \
     | grep -E '^\s*if \[ -f .+_classifier_invoke.+\]\; then' > /dev/null; then
  pass_msg "classify_issue guards helper invocation with [ -f ... ]"
else
  fail_msg "expected fail-OPEN guard, got none"
fi

# -------------------------------------------------------------------------
# Test 6: operator-facing docs contain no mock-web-eval/scripts/eval-classifier-invoke.sh token
# -------------------------------------------------------------------------
echo "Test 6: skills/run/SKILL.md and docs/architecture.md contain no mock-web-eval/scripts/eval-classifier-invoke.sh token"
inc
_doc_hits=$(grep -cF 'mock-web-eval/scripts/eval-classifier-invoke.sh' \
              "$ROOT/skills/run/SKILL.md" "$ROOT/docs/architecture.md" 2>/dev/null \
              | awk -F: '{sum+=$2} END {print sum+0}')
if [ "${_doc_hits:-0}" -eq 0 ]; then
  pass_msg "no mock-web-eval/scripts/eval-classifier-invoke.sh token in operator-facing docs"
else
  fail_msg "expected 0 hits, got $_doc_hits"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
