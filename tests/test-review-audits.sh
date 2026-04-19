#!/bin/bash
set -euo pipefail

# Tests for .claude-pipeline/scripts/review-audits.sh.
#
# Uses synthetic runs.log + tool-use.log + subagents.log under a temp dir
# so the test does not depend on live logs. All gh/git calls in the script
# must degrade gracefully when no repo/gh is available — the test runs in a
# tmp dir that is not a git repo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/review-audits.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.claude/logs/subagents" "$TMP/.claude/scripts"

# Minimal pipeline.config with path-family keys so signal computation works.
cat > "$TMP/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_PATH_A_SKILLS_EXECUTE="superpowers:verification-before-completion"
PIPELINE_PATH_B_SKILLS_EXECUTE="superpowers:test-driven-development superpowers:verification-before-completion"
PIPELINE_PATH_C_SKILLS_EXECUTE="superpowers:subagent-driven-development"
EOF

cp "$SCRIPT_UNDER_TEST" "$TMP/.claude/scripts/review-audits.sh"
chmod +x "$TMP/.claude/scripts/review-audits.sh"

UUID_A="11111111-1111-1111-1111-111111111111"
UUID_B="22222222-2222-2222-2222-222222222222"
UUID_C="33333333-3333-3333-3333-333333333333"

RUNS_LOG="$TMP/.claude/logs/runs.log"
TOOL_LOG="$TMP/.claude/logs/tool-use.log"
SUBAGENTS_LOG="$TMP/.claude/logs/subagents.log"

printf '2026-04-18T10:00:00Z\tsession=%s\tissue=900\tpath=A\tskill=execute-issue-plan\tworktree=/tmp/a\n' "$UUID_A"  > "$RUNS_LOG"
printf '2026-04-18T11:00:00Z\tsession=%s\tissue=901\tpath=B\tskill=execute-issue-plan\tworktree=/tmp/b\n' "$UUID_B" >> "$RUNS_LOG"
printf '2026-04-18T12:00:00Z\tsession=%s\tissue=902\tpath=C\tskill=execute-issue-plan\tworktree=/tmp/c\n' "$UUID_C" >> "$RUNS_LOG"

# tool-use.log: session A follows expected (single skill, in order); session B
# invokes skills in the wrong order (verification first, TDD second) -> 1
# deviation. Session C matches expected.
printf '2026-04-18T10:00:01Z\tSkill\tsession=%s\tskill=superpowers:verification-before-completion\n' "$UUID_A"  > "$TOOL_LOG"
printf '2026-04-18T11:00:02Z\tSkill\tsession=%s\tskill=superpowers:verification-before-completion\n' "$UUID_B" >> "$TOOL_LOG"
printf '2026-04-18T11:00:03Z\tSkill\tsession=%s\tskill=superpowers:test-driven-development\n' "$UUID_B"       >> "$TOOL_LOG"
printf '2026-04-18T12:00:01Z\tSkill\tsession=%s\tskill=superpowers:subagent-driven-development\n' "$UUID_C"   >> "$TOOL_LOG"

# subagents.log + one JSON for session B (code-reviewer)
printf '2026-04-18T11:30:00Z\t%s\tReview\t0\t0\t0\t%s_code-reviewer.json\n' "$UUID_B" "$UUID_B" > "$SUBAGENTS_LOG"
cat > "$TMP/.claude/logs/subagents/${UUID_B}_code-reviewer.json" <<EOF
{"session_id":"${UUID_B}","subagent_type":"code-reviewer","description":"Review"}
EOF

cd "$TMP"

# -------------------------------------------------------------------------
# Test 1: default (no flags) -> table contains all three issues
# -------------------------------------------------------------------------
echo "Test 1: default run shows all three issues"
inc
OUT=$(bash .claude/scripts/review-audits.sh 2>&1 || true)
ok=1
echo "$OUT" | grep -q '#900' || { fail_msg "default output missing #900"; ok=0; }
if [ "$ok" = "1" ]; then echo "$OUT" | grep -q '#901' || { fail_msg "default output missing #901"; ok=0; }; fi
if [ "$ok" = "1" ]; then echo "$OUT" | grep -q '#902' || { fail_msg "default output missing #902"; ok=0; }; fi
[ "$ok" = "1" ] && pass_msg "all three issues present in table"

# -------------------------------------------------------------------------
# Test 2: --path B filters to issue 901
# -------------------------------------------------------------------------
echo "Test 2: --path B includes #901, excludes #900"
inc
OUT=$(bash .claude/scripts/review-audits.sh --path B 2>&1 || true)
if echo "$OUT" | grep -q '#901' && ! echo "$OUT" | grep -q '#900'; then
  pass_msg "--path B filters correctly"
else
  fail_msg "expected only #901; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 3: --deviations shows #901 (PATH B with wrong first skill), hides #900
# -------------------------------------------------------------------------
echo "Test 3: --deviations includes #901 only"
inc
OUT=$(bash .claude/scripts/review-audits.sh --deviations 2>&1 || true)
if echo "$OUT" | grep -q '#901' && ! echo "$OUT" | grep -q '#900'; then
  pass_msg "--deviations surfaces only deviating rows"
else
  fail_msg "expected #901 only; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 4: --issue 901 shows detail view with session id
# -------------------------------------------------------------------------
echo "Test 4: --issue 901 renders detail view"
inc
OUT=$(bash .claude/scripts/review-audits.sh --issue 901 2>&1 || true)
if echo "$OUT" | grep -q 'issue #901' && echo "$OUT" | grep -q "$UUID_B"; then
  pass_msg "detail view present"
else
  fail_msg "detail view missing header or session id; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 5: --last 1 shows only the most recent (#902)
# -------------------------------------------------------------------------
echo "Test 5: --last 1 shows only #902"
inc
OUT=$(bash .claude/scripts/review-audits.sh --last 1 2>&1 || true)
if echo "$OUT" | grep -q '#902' && ! echo "$OUT" | grep -q '#900'; then
  pass_msg "--last 1 limits to most recent row"
else
  fail_msg "expected only #902; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 6: --since 2026-04-19 yields no matches
# -------------------------------------------------------------------------
echo "Test 6: --since 2026-04-19 returns 'No runs match the filter'"
inc
OUT=$(bash .claude/scripts/review-audits.sh --since 2026-04-19 2>&1 || true)
if echo "$OUT" | grep -qi 'no runs match'; then
  pass_msg "empty-filter message shown"
else
  fail_msg "expected 'No runs match the filter' message; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 7: empty runs.log prints the 'No runs logged yet' message
# -------------------------------------------------------------------------
echo "Test 7: empty runs.log -> 'No runs logged yet'"
inc
EMPTY_TMP=$(mktemp -d)
mkdir -p "$EMPTY_TMP/.claude/logs" "$EMPTY_TMP/.claude/scripts"
cp "$TMP/pipeline.config" "$EMPTY_TMP/pipeline.config"
cp "$SCRIPT_UNDER_TEST" "$EMPTY_TMP/.claude/scripts/review-audits.sh"
chmod +x "$EMPTY_TMP/.claude/scripts/review-audits.sh"
OUT=$(cd "$EMPTY_TMP" && bash .claude/scripts/review-audits.sh 2>&1 || true)
rm -rf "$EMPTY_TMP"
if echo "$OUT" | grep -qi 'no runs logged yet'; then
  pass_msg "empty-runs.log message shown"
else
  fail_msg "expected 'No runs logged yet'; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 8: unknown flag exits 2 with usage
# -------------------------------------------------------------------------
echo "Test 8: unknown flag exits non-zero"
inc
set +e
bash .claude/scripts/review-audits.sh --bogus-flag >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  pass_msg "unknown flag exits non-zero (rc=$RC)"
else
  fail_msg "expected non-zero exit for --bogus-flag"
fi

# -------------------------------------------------------------------------
# Test 9: summary table for default run mentions PATH A/B/C
# -------------------------------------------------------------------------
echo "Test 9: default run includes summary grouped by path"
inc
OUT=$(bash .claude/scripts/review-audits.sh 2>&1 || true)
ok=1
echo "$OUT" | grep -q 'SUMMARY' || { fail_msg "summary section missing"; ok=0; }
[ "$ok" = "1" ] && pass_msg "summary section present"

# -------------------------------------------------------------------------
# Test 10: summary reports the most-common deviation reason for a path
# -------------------------------------------------------------------------
echo "Test 10: summary surfaces the most-common deviation reason"
inc
OUT=$(bash .claude/scripts/review-audits.sh 2>&1 || true)
# Session B's first skill is verification-before-completion, expected
# test-driven-development -> the deviation message should surface.
if echo "$OUT" | grep -qE 'Most-common deviation' && \
   echo "$OUT" | grep -qE 'test-driven-development.*saw.*verification-before-completion'; then
  pass_msg "Most-common deviation column present with expected reason"
else
  fail_msg "expected 'Most-common deviation' column with session B's deviation; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 11: PATH C detail view surfaces tdd-implementer label
# -------------------------------------------------------------------------
echo "Test 11: PATH C detail view includes tdd-implementer label"
inc
OUT=$(bash .claude/scripts/review-audits.sh --issue 902 2>&1 || true)
if echo "$OUT" | grep -q 'tdd-implementer:'; then
  pass_msg "PATH C detail view surfaces tdd-implementer line"
else
  fail_msg "PATH C detail view missing tdd-implementer line; got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 12: --last with non-numeric value errors out instead of crashing
# -------------------------------------------------------------------------
echo "Test 12: --last foo errors with usage, exits 1"
inc
set +e
OUT=$(bash .claude/scripts/review-audits.sh --last foo 2>&1)
RC=$?
set -e
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -qiE 'non-negative integer|--last'; then
  pass_msg "--last foo rejected with exit 1"
else
  fail_msg "expected exit 1 + error message for --last foo (rc=$RC); got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 13: --path with invalid value errors out instead of silently matching nothing
# -------------------------------------------------------------------------
echo "Test 13: --path X errors with usage, exits 1"
inc
set +e
OUT=$(bash .claude/scripts/review-audits.sh --path X 2>&1)
RC=$?
set -e
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -qiE 'A\|B\|C|--path'; then
  pass_msg "--path X rejected with exit 1"
else
  fail_msg "expected exit 1 + error message for --path X (rc=$RC); got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 14: --since with unparseable date errors out
# -------------------------------------------------------------------------
echo "Test 14: --since not-a-date errors with usage, exits 1"
inc
set +e
OUT=$(bash .claude/scripts/review-audits.sh --since not-a-date 2>&1)
RC=$?
set -e
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -qiE 'parseable date|--since'; then
  pass_msg "--since not-a-date rejected with exit 1"
else
  fail_msg "expected exit 1 + error message for --since not-a-date (rc=$RC); got:"
  echo "$OUT" | sed 's/^/    /'
fi

# -------------------------------------------------------------------------
# Test 15: valid values still pass through (regression — make sure
# validation doesn't over-reject).
# -------------------------------------------------------------------------
echo "Test 15: valid --last 2 / --path A / --since 2026-04-18 still work"
inc
set +e
bash .claude/scripts/review-audits.sh --last 2 >/dev/null 2>&1
RC1=$?
bash .claude/scripts/review-audits.sh --path A >/dev/null 2>&1
RC2=$?
bash .claude/scripts/review-audits.sh --since 2026-04-18 >/dev/null 2>&1
RC3=$?
set -e
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 0 ]; then
  pass_msg "valid inputs accepted"
else
  fail_msg "valid inputs rejected (last=$RC1 path=$RC2 since=$RC3)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
