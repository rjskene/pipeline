#!/bin/bash
set -uo pipefail

# Guard (issue #1464): PIPELINE_PRE_PR_REVIEW (default true) — `false` skips
# execute-issue-plan Step 8 (8a–8e) on PATH A/B/C exactly as on PATH D. The
# knob is the calibration A/B lever for the pre-PR review loop, so the skill
# text, the reference, and the config example must all name it.
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/execute-issue-plan/SKILL.md"
REF="$ROOT/skills/execute-issue-plan/references/pre-pr-review-loop.md"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"
ROUTING="$ROOT/skills/fullsend/references/dispatch-routing.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$SKILL" "$REF" "$EXAMPLE" "$ROUTING"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

# --- (1) SKILL.md Step 8 paragraph names the knob and the skip log line -----
# The Step 8 paragraph is the line starting `8. **Pre-PR code review loop.**`.
STEP8="$(grep -E '^8\. \*\*Pre-PR code review loop\.\*\*' "$SKILL")"
inc
if printf '%s\n' "$STEP8" | grep -qF 'PIPELINE_PRE_PR_REVIEW'; then
  pass_msg "SKILL.md Step 8 names PIPELINE_PRE_PR_REVIEW"
else
  fail_msg "SKILL.md Step 8 must name PIPELINE_PRE_PR_REVIEW"
fi
inc
if printf '%s\n' "$STEP8" | grep -qF 'PRE-PR-REVIEW: skipped reason=knob'; then
  pass_msg "SKILL.md Step 8 names the 'PRE-PR-REVIEW: skipped reason=knob' line"
else
  fail_msg "SKILL.md Step 8 must name 'PRE-PR-REVIEW: skipped reason=knob'"
fi

# --- (2) reference names the knob near the top -----------------------------
inc
if head -n 10 "$REF" | grep -qF 'PIPELINE_PRE_PR_REVIEW'; then
  pass_msg "pre-pr-review-loop.md names PIPELINE_PRE_PR_REVIEW in its first 10 lines"
else
  fail_msg "pre-pr-review-loop.md must name PIPELINE_PRE_PR_REVIEW in its first 10 lines"
fi

# --- (3) config example documents the knob as a COMMENTED line -------------
inc
if grep -Eq '^#[[:space:]]*PIPELINE_PRE_PR_REVIEW=' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_PRE_PR_REVIEW documented as a commented template line"
else
  fail_msg "example: PIPELINE_PRE_PR_REVIEW missing a commented '#PIPELINE_PRE_PR_REVIEW=' line"
fi

# --- (4) live pipeline.config (host-only): any value is true|false ---------
inc
if [ -f "$LIVE" ]; then
  bad="$(grep -E '^[[:space:]]*PIPELINE_PRE_PR_REVIEW=' "$LIVE" \
           | grep -Ev '^[[:space:]]*PIPELINE_PRE_PR_REVIEW="?(true|false)"?[[:space:]]*(#.*)?$' || true)"
  if [ -z "$bad" ]; then
    pass_msg "live pipeline.config: PIPELINE_PRE_PR_REVIEW absent or true|false"
  else
    fail_msg "live pipeline.config: PIPELINE_PRE_PR_REVIEW must be true|false (got: $bad)"
  fi
else
  pass_msg "live pipeline.config absent (CI) — nothing to scan"
fi

# --- (5) #1468: PATH A/B execute prompt templates carry PRE_PR_REVIEW= -----
# Select ONLY the A/B prompt lines (the PATH D template stays token-free).
AB_PROMPTS="$(grep -A1 -E "description='execute-issue-plan #<N> \(PATH [AB] inline\)'" "$ROUTING" | grep "prompt: 'cd" || true)"
AB_COUNT="$(printf '%s\n' "$AB_PROMPTS" | grep -c "prompt: 'cd" || true)"
AB_TOK="$(printf '%s\n' "$AB_PROMPTS" | grep -c 'PRE_PR_REVIEW=' || true)"
inc
if [ "$AB_COUNT" = "2" ] && [ "$AB_TOK" = "2" ]; then
  pass_msg "dispatch-routing.md: both PATH A/B execute prompts carry PRE_PR_REVIEW="
else
  fail_msg "dispatch-routing.md: expected exactly 2 PATH A/B prompt lines both carrying PRE_PR_REVIEW= (lines=$AB_COUNT, with-token=$AB_TOK)"
fi
inc
if grep -F "(PATH D collapsed inline tdd)" "$ROUTING" | grep -qF 'PRE_PR_REVIEW='; then
  fail_msg "dispatch-routing.md: PATH D prompt must NOT carry PRE_PR_REVIEW= (D skips Step 8 regardless)"
else
  pass_msg "dispatch-routing.md: PATH D prompt carries no PRE_PR_REVIEW="
fi

# --- (6) #1468: PATH C bullet tells the orchestrator to honor the token -----
inc
if grep -E '^   - \*\*PATH C\*\* \(`multi-task`\): dispatch inline' "$ROUTING" | grep -qF 'PRE_PR_REVIEW'; then
  pass_msg "dispatch-routing.md: PATH C bullet names PRE_PR_REVIEW"
else
  fail_msg "dispatch-routing.md: PATH C bullet must name PRE_PR_REVIEW"
fi

# --- (7) #1468: reference names the prompt token near the top --------------
inc
if head -n 10 "$REF" | grep -qF 'PRE_PR_REVIEW=off'; then
  pass_msg "pre-pr-review-loop.md names PRE_PR_REVIEW=off in its first 10 lines"
else
  fail_msg "pre-pr-review-loop.md must name PRE_PR_REVIEW=off in its first 10 lines"
fi

# --- (8) #1468: SKILL.md Step 8 keys off the dispatch-prompt token ----------
inc
if printf '%s\n' "$STEP8" | grep -qF 'PRE_PR_REVIEW=off'; then
  pass_msg "SKILL.md Step 8 names the PRE_PR_REVIEW=off prompt token"
else
  fail_msg "SKILL.md Step 8 must name the PRE_PR_REVIEW=off prompt token"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
