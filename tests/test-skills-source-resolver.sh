#!/bin/bash
set -uo pipefail

# Contract test: every consumer-facing skill (except skills/doctor, which has
# the source at a deliberately different position) MUST source
# scripts/_resolve-plugin-root.sh within its ## Boot block (first 30 lines).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."

SKILLS=(
  "skills/status/SKILL.md"
  "skills/run/SKILL.md"
  "skills/fullsend/SKILL.md"
  "skills/create-issues/SKILL.md"
  "skills/execute-issue-plan/SKILL.md"
  "skills/evaluate-issue-pr/SKILL.md"
  "skills/plan-issue/SKILL.md"
  "skills/classify-issue/SKILL.md"
  "skills/evaluate-issue-plan/SKILL.md"
  "skills/doctor/SKILL.md"
)

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

for rel in "${SKILLS[@]}"; do
  F="$REPO_ROOT/$rel"
  if [ ! -f "$F" ]; then
    fail_msg "$rel: file not found"
    continue
  fi
  if head -n 30 "$F" | grep -qE 'source [^ ]*_resolve-plugin-root\.sh'; then
    pass_msg "$rel sources resolver in first 30 lines"
  else
    fail_msg "$rel does NOT source resolver in first 30 lines"
  fi
done

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
