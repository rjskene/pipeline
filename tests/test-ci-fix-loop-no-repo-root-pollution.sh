#!/usr/bin/env bash
# Regression test for #362.
#
# Pins the contract: running tests/test-ci-fix-loop.sh with
# PIPELINE_LOGS_ENABLED=true must NOT create any new
# ci-fix-*-attempt-*.log files under REPO_ROOT/.claude/logs/.
#
# Why this matters: check-ci-fix-loop.sh honors PIPELINE_LOGS_ENABLED
# and writes to $(pwd)/.claude/logs/. The test-ci-fix-loop.sh fixtures
# must cd into a tmpdir before invoking the helper; otherwise logs
# land in REPO_ROOT and collide across fixtures and full-suite runs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

pre=$(ls "$REPO_ROOT/.claude/logs/"ci-fix-*-attempt-*.log 2>/dev/null | wc -l)
PIPELINE_LOGS_ENABLED=true PIPELINE_REPO="env-leak/test" \
  bash "$REPO_ROOT/tests/test-ci-fix-loop.sh" >/dev/null 2>&1 || true
post=$(ls "$REPO_ROOT/.claude/logs/"ci-fix-*-attempt-*.log 2>/dev/null | wc -l)

if [ "$post" -ne "$pre" ]; then
  echo "FAIL: test-ci-fix-loop.sh polluted REPO_ROOT/.claude/logs/ (pre=$pre post=$post)"
  exit 1
fi
echo "PASS: test-ci-fix-loop.sh did not pollute REPO_ROOT/.claude/logs/"
