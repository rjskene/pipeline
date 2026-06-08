#!/bin/bash
set -euo pipefail

# Regression guard for issue #984: skill prose is authored in Claude Code (CC)
# tool names, and `skills/references/codex-tools.md` is the canonical bridge to
# the Codex equivalents. This test keeps that bridge honest:
#
#   (a) EXISTS    — `skills/references/codex-tools.md` exists and is non-empty.
#   (b) COVERAGE  — every CC tool name from the closed vocabulary
#                   (Task|Agent|TodoWrite|Read|Write|Edit|Bash|Grep|Glob|Skill
#                   plus mcp__playwright_*) that is actually referenced (in
#                   backtick form) across the skills/*/SKILL.md bodies has a
#                   mapping entry in the reference's left column. No skill may
#                   reference a CC-only tool name that lacks a codex-tools.md
#                   mapping. (Native-everywhere shell verbs beyond the closed
#                   vocabulary are intentionally NOT checked.)
#   (c) POINTER   — every skills/*/SKILL.md contains a relative reference to
#                   `references/codex-tools.md`.
#
# Modelled on tests/test-skills-no-bare-claude-scripts.sh and
# tests/test-skill-boot-section.sh: pure bash, set -euo pipefail, enumerate
# skills/*/SKILL.md, PASS/FAIL counters, exit non-zero on failure.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_ROOT="$REPO_ROOT/skills"
REF="$SKILL_ROOT/references/codex-tools.md"

# Closed CC tool vocabulary. mcp__playwright_* is handled separately because
# its trailing `*` is a regex metacharacter in the reference's left column.
CLOSED_VOCAB=(Task Agent TodoWrite Read Write Edit Bash Grep Glob Skill)

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== skills codex tool-vocab guard (#984) ==="

[ -d "$SKILL_ROOT" ] || { echo "FAIL: $SKILL_ROOT missing"; exit 1; }

SKILLS=$(find "$SKILL_ROOT" -maxdepth 2 -name SKILL.md | sort)
[ -n "$SKILLS" ] || { echo "FAIL: no SKILL.md files found under $SKILL_ROOT"; exit 1; }

# ---------------------------------------------------------------------------
# (a) EXISTS — reference is present and non-empty.
# ---------------------------------------------------------------------------
if [ -s "$REF" ]; then
  pass_msg "reference exists and is non-empty: skills/references/codex-tools.md"
else
  fail_msg "reference missing or empty: skills/references/codex-tools.md"
fi

# ---------------------------------------------------------------------------
# (b) COVERAGE — every referenced closed-vocab token is mapped in the
#     reference's left column. Match the reference's left-column token format
#     exactly: tokens are written in backticks (e.g. `Read`, `mcp__playwright_*`).
# ---------------------------------------------------------------------------
uncovered=""
for tok in "${CLOSED_VOCAB[@]}"; do
  # Is `tok` referenced in backtick form anywhere in a SKILL.md body?
  if grep -rqlE "\`${tok}\`" $SKILLS; then
    # It is referenced — require a backticked left-column entry in the reference.
    if ! grep -qE "\`${tok}\`" "$REF"; then
      uncovered="${uncovered} \`${tok}\`"
    fi
  fi
done

# mcp__playwright_* — `*` is literal in the source text but a regex metachar,
# so quote it via grep -F for both the body scan and the reference lookup.
if grep -rqlF 'mcp__playwright_*' $SKILLS; then
  if ! grep -qF 'mcp__playwright_*' "$REF"; then
    uncovered="${uncovered} \`mcp__playwright_*\`"
  fi
fi

if [ -z "$uncovered" ]; then
  pass_msg "every referenced CC tool token is mapped in codex-tools.md"
else
  fail_msg "CC tool token(s) referenced in skills/ with no codex-tools.md mapping:${uncovered}"
fi

# ---------------------------------------------------------------------------
# (c) POINTER — every SKILL.md carries a relative reference to the table.
# ---------------------------------------------------------------------------
missing_pointer=""
for skill_md in $SKILLS; do
  rel="${skill_md#$REPO_ROOT/}"
  if ! grep -qF 'references/codex-tools.md' "$skill_md"; then
    missing_pointer="${missing_pointer} ${rel}"
  fi
done

if [ -z "$missing_pointer" ]; then
  pass_msg "every SKILL.md references references/codex-tools.md"
else
  fail_msg "SKILL.md missing references/codex-tools.md pointer:${missing_pointer}"
fi

echo
echo "Result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
