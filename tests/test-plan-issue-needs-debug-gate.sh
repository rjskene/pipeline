#!/bin/bash
set -euo pipefail
# Guard: the needs-debug / --debug-first root-cause diagnosis gate (#997).
# Static grep-based contract over the now-edited skills (mirrors the
# tests/test-plan-issue-needs-browser-predicates.sh style). Asserts that
# skills/plan-issue/SKILL.md documents the gate (label, flag, sub-skill,
# comment name, gate condition) and that skills/fullsend/SKILL.md propagates
# the one-off --debug-first flag to the dispatched plan-issue stage. Runtime
# behavior is covered by the impl commits; this is a documentation/contract
# guard so the gate cannot silently regress.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_FILE="$REPO_ROOT/skills/plan-issue/SKILL.md"
FULLSEND_FILE="$REPO_ROOT/skills/fullsend/SKILL.md"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

assert_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  inc
  if grep -qF -- "$needle" "$file"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

echo "plan-issue needs-debug / --debug-first root-cause diagnosis gate (#997)"

# (a) references the needs-debug label
assert_contains "$PLAN_FILE" "needs-debug" "plan-issue references needs-debug label"
# (b) references the --debug-first flag
assert_contains "$PLAN_FILE" "--debug-first" "plan-issue references --debug-first flag"
# (c) references the systematic-debugging superpower
assert_contains "$PLAN_FILE" "superpowers:systematic-debugging" "plan-issue references superpowers:systematic-debugging"
# (d) names the Root-Cause Diagnosis comment
assert_contains "$PLAN_FILE" "## Root-Cause Diagnosis" "plan-issue names the ## Root-Cause Diagnosis comment"
# (e) documents the gate condition (needs-debug present OR --debug-first)
inc
if grep -qF -- "needs-debug" "$PLAN_FILE" \
   && grep -qiE 'needs-debug.*OR.*--debug-first|--debug-first.*OR.*needs-debug|needs-debug.*OR `--debug-first`|`--debug-first` was passed' "$PLAN_FILE"; then
  pass_msg "plan-issue documents the gate condition (needs-debug present OR --debug-first)"
else
  fail_msg "plan-issue documents the gate condition (needs-debug present OR --debug-first)"
fi

# (f) fullsend propagates --debug-first to the dispatched plan stage
assert_contains "$FULLSEND_FILE" "--debug-first" "fullsend references --debug-first flag"
inc
if grep -qiE '\-\-debug-first.*(propagat|dispatch|plan-issue)|(propagat|dispatch).*--debug-first' "$FULLSEND_FILE"; then
  pass_msg "fullsend propagates --debug-first to the dispatched plan stage"
else
  fail_msg "fullsend propagates --debug-first to the dispatched plan stage"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
