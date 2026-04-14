#!/bin/bash
set -euo pipefail

# Tests for the gate pre-population logic in spawn-claude.sh.template
#
# Runs the pre-population block in isolation (same pattern as
# test_install_superpowers.sh) with a temp WORKTREE_PATH that contains or
# omits pipeline-config.json, then asserts presence/absence/shape of
# .claude/state/skill-gate.json.

PASS=0
FAIL=0
TESTS=0

assert_contains() {
  local label="$1" output="$2" expected="$3"
  TESTS=$((TESTS + 1))
  if echo "$output" | grep -qF "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $expected"
    echo "    got: $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  TESTS=$((TESTS + 1))
  if echo "$output" | grep -qF "$unexpected"; then
    echo "  FAIL: $label"
    echo "    expected NOT to contain: $unexpected"
    echo "    got: $output"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_file_exists() {
  local label="$1" filepath="$2"
  TESTS=$((TESTS + 1))
  if [ -f "$filepath" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected file to exist: $filepath"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_absent() {
  local label="$1" filepath="$2"
  TESTS=$((TESTS + 1))
  if [ ! -f "$filepath" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected file to be absent: $filepath"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: run only the pre-population block from spawn-claude.sh.template.
# Args: <worktree_path> [skill]
run_gate_prepop() {
  local worktree_path="$1"
  local skill="${2:-execute-issue-plan}"
  bash -c '
    WORKTREE_PATH="'"$worktree_path"'"
    SKILL="'"$skill"'"
    if [ -f "$WORKTREE_PATH/.claude/pipeline-config.json" ]; then
      python3 <<PYEOF
import json
from pathlib import Path
from datetime import datetime, timezone

wt = Path("'"$worktree_path"'")
config = json.load(open(wt / ".claude/pipeline-config.json"))
required = config.get("skill_gates", {}).get("'"$skill"'", [])
if required:
    state = {
        "active_skill": "'"$skill"'",
        "required": required,
        "satisfied": [],
        "activated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "session_id": "unknown",
    }
    (wt / ".claude/state").mkdir(parents=True, exist_ok=True)
    json.dump(state, open(wt / ".claude/state/skill-gate.json", "w"), indent=2)
PYEOF
    fi
  ' 2>&1
}

# --- Test 1: No pipeline-config.json present ---
echo "Test 1: no pipeline-config.json — no state file should be written"
T1=$(mktemp -d)
mkdir -p "$T1/.claude"
# Intentionally do NOT create pipeline-config.json

run_gate_prepop "$T1"
assert_file_absent "no skill-gate.json written" "$T1/.claude/state/skill-gate.json"
rm -rf "$T1"

# --- Test 2: Skill has no configured gates ---
echo "Test 2: pipeline-config.json exists but skill not in skill_gates"
T2=$(mktemp -d)
mkdir -p "$T2/.claude"
cat > "$T2/.claude/pipeline-config.json" <<'JSON'
{
  "skill_gates": {
    "plan-issue": ["superpowers:writing-plans"]
  }
}
JSON

run_gate_prepop "$T2" "some-unlisted-skill"
assert_file_absent "no skill-gate.json for unlisted skill" "$T2/.claude/state/skill-gate.json"
rm -rf "$T2"

# --- Test 3: Skill has gates — state file written with correct shape ---
echo "Test 3: skill has gates — state file written with correct JSON shape"
T3=$(mktemp -d)
mkdir -p "$T3/.claude"
cat > "$T3/.claude/pipeline-config.json" <<'JSON'
{
  "skill_gates": {
    "plan-issue": ["superpowers:writing-plans"],
    "execute-issue-plan": ["superpowers:subagent-driven-development"]
  }
}
JSON

run_gate_prepop "$T3" "plan-issue"
assert_file_exists "skill-gate.json created" "$T3/.claude/state/skill-gate.json"

JSON_CONTENT=$(cat "$T3/.claude/state/skill-gate.json")

# Validate shape with python3
JSON_CHECK=$(python3 -c "
import json, sys
data = json.loads('''$JSON_CONTENT''')
errors = []
if data.get('active_skill') != 'plan-issue':
    errors.append('active_skill wrong: ' + repr(data.get('active_skill')))
if data.get('required') != ['superpowers:writing-plans']:
    errors.append('required wrong: ' + repr(data.get('required')))
if data.get('satisfied') != []:
    errors.append('satisfied not empty: ' + repr(data.get('satisfied')))
if 'activated_at' not in data:
    errors.append('activated_at missing')
if data.get('session_id') != 'unknown':
    errors.append('session_id wrong: ' + repr(data.get('session_id')))
if errors:
    print('ERRORS: ' + '; '.join(errors))
else:
    print('OK')
" 2>&1)

assert_contains "JSON shape valid" "$JSON_CHECK" "OK"
assert_contains "active_skill is plan-issue" "$JSON_CONTENT" '"plan-issue"'
assert_contains "required contains superpowers:writing-plans" "$JSON_CONTENT" '"superpowers:writing-plans"'
assert_contains "satisfied is empty array" "$JSON_CONTENT" '"satisfied": []'
assert_contains "session_id is unknown" "$JSON_CONTENT" '"unknown"'
assert_contains "activated_at key present" "$JSON_CONTENT" '"activated_at"'
rm -rf "$T3"

# --- Test 4: No superpowers manifest — gate still works ---
echo "Test 4: no superpowers manifest present — gate logic unaffected"
T4=$(mktemp -d)
mkdir -p "$T4/.claude"
# pipeline-config.json present but no installed_plugins.json
cat > "$T4/.claude/pipeline-config.json" <<'JSON'
{
  "skill_gates": {
    "execute-issue-plan": ["superpowers:subagent-driven-development"]
  }
}
JSON
# Explicitly no plugins manifest

run_gate_prepop "$T4" "execute-issue-plan"
assert_file_exists "skill-gate.json written without superpowers manifest" "$T4/.claude/state/skill-gate.json"

JSON_CONTENT4=$(cat "$T4/.claude/state/skill-gate.json")
assert_contains "active_skill correct" "$JSON_CONTENT4" '"execute-issue-plan"'
assert_contains "required correct" "$JSON_CONTENT4" '"superpowers:subagent-driven-development"'
rm -rf "$T4"

# --- Test 5: Default execute-issue-plan skill ---
echo "Test 5: default SKILL (execute-issue-plan) writes correct gate"
T5=$(mktemp -d)
mkdir -p "$T5/.claude"
cat > "$T5/.claude/pipeline-config.json" <<'JSON'
{
  "skill_gates": {
    "plan-issue": ["superpowers:writing-plans"],
    "execute-issue-plan": ["superpowers:subagent-driven-development"],
    "create-issues": ["superpowers:brainstorming"],
    "evaluate-issue-pr": ["superpowers:subagent-driven-development"]
  }
}
JSON

# Call without specifying a skill — should default to execute-issue-plan
run_gate_prepop "$T5"
assert_file_exists "skill-gate.json created for default skill" "$T5/.claude/state/skill-gate.json"

JSON_CONTENT5=$(cat "$T5/.claude/state/skill-gate.json")
assert_contains "active_skill is execute-issue-plan" "$JSON_CONTENT5" '"execute-issue-plan"'
assert_contains "required is subagent-driven-development" "$JSON_CONTENT5" '"superpowers:subagent-driven-development"'
assert_contains "satisfied is empty" "$JSON_CONTENT5" '"satisfied": []'
assert_contains "session_id is unknown" "$JSON_CONTENT5" '"unknown"'
rm -rf "$T5"

# --- Summary ---
echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
