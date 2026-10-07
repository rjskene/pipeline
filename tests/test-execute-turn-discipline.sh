#!/bin/bash
set -uo pipefail
#
# #1463 — PATH B TURN DISCIPLINE (shape test, token presence only).
#
# The PATH B inline execute agent and the tdd-implementer leaf must carry the
# turn-discipline cues (targeted test inside RED/GREEN; GREEN + commit in one
# Bash call), and evaluate-issue-pr's Executable verification section must
# carry the one-Bash-call probe shape. Each region is extracted from the BODY
# (frontmatter stripped, tests/_lib/skill-body.sh) so the YAML description
# line cannot satisfy a needle. An empty region FAILS (non-vacuity).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tests/_lib/skill-body.sh
source "$SCRIPT_DIR/_lib/skill-body.sh"

EXEC="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"
AGENT="$REPO_ROOT/agents/tdd-implementer.md"
EVAL="$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Region A: PATH B paragraph up to the next **PATH C line, newlines flattened.
REGION_A="$(skill_body "$EXEC" | awk '/\*\*PATH B single execute agent\.\*\*/{on=1} on && /\*\*PATH C/{exit} on' | tr '\n' ' ')"
# Region B: tdd-implementer body.
REGION_B="$(skill_body "$AGENT" | tr '\n' ' ')"
# Region C: evaluate-issue-pr ## Executable verification up to the next ## heading.
REGION_C="$(skill_body "$EVAL" | awk '/^## Executable verification/{on=1; print; next} on && /^## /{exit} on' | tr '\n' ' ')"

# check <label> <region-name> <region> <mode:ci|fixed> <needle>
check() {
  local label="$1" rname="$2" region="$3" mode="$4" needle="$5"
  if [ -z "${region// /}" ]; then
    fail_msg "$label (could not extract region $rname)"
    return
  fi
  local flag=-qF
  [ "$mode" = ci ] && flag=-qiF
  if printf '%s' "$region" | grep "$flag" -- "$needle"; then
    pass_msg "$label"
  else
    fail_msg "$label (region $rname missing: $needle)"
  fi
}

echo "-- execute-issue-plan PATH B paragraph --"
check "PATH B: targeted test only inside RED/GREEN" A "$REGION_A" ci 'targeted test'
check "PATH B: GREEN and commit share one Bash call" A "$REGION_A" fixed '&& git commit'
echo "-- agents/tdd-implementer.md --"
check "tdd-implementer: targeted test only inside RED/GREEN" B "$REGION_B" ci 'targeted test'
check "tdd-implementer: GREEN and commit share one Bash call" B "$REGION_B" fixed '&& git commit'
echo "-- evaluate-issue-pr Executable verification --"
check "pr-eval: positive+negative probe in one Bash call" C "$REGION_C" ci 'one Bash call'

echo ""
echo "================================"
echo "  $((PASS + FAIL)) tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
