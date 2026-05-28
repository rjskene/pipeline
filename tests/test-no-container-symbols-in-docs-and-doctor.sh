#!/bin/bash
set -uo pipefail

# Regression guard for #514 Task 7: ensures the container-isolation excision
# stays excised from docs/, skills/doctor/, and scripts/doctor.sh. The full
# container/eval-isolation symbol set must not reappear in any of these
# surfaces. The grep targets are the exact set called out in the issue
# acceptance criteria.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

PATTERN='container_assets_unwired|container_skills_validity|PIPELINE_EVAL_ISOLATION|--container-mode|PIPELINE_EVAL_CLASSIFIER|PIPELINE_EVAL_CONTAINER|PIPELINE_CONTAINER_'

check_path() {
  local path="$1"
  local label="$2"
  local hits
  if [ -d "$REPO_ROOT/$path" ]; then
    hits="$(grep -rE "$PATTERN" "$REPO_ROOT/$path" 2>/dev/null || true)"
  elif [ -f "$REPO_ROOT/$path" ]; then
    hits="$(grep -E "$PATTERN" "$REPO_ROOT/$path" 2>/dev/null || true)"
  else
    fail_msg "$label: path $path does not exist"
    return
  fi
  if [ -z "$hits" ]; then
    pass_msg "$label: zero container symbols"
  else
    fail_msg "$label: container symbols still present"
    printf '%s\n' "$hits" | sed 's/^/    /'
  fi
}

check_path docs/ "docs/"
check_path skills/doctor/ "skills/doctor/"
check_path scripts/doctor.sh "scripts/doctor.sh"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
