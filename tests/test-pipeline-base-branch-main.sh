#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/pipeline.config"
EX="$REPO_ROOT/pipeline.config.example"
README="$REPO_ROOT/README.md"
CI="$REPO_ROOT/.github/workflows/ci.yml"
PASS=0; FAIL=0; SKIP=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# pipeline.config is gitignored — only enforce when present (e.g., local dev machine).
if [ -f "$CFG" ]; then
  assert "pipeline.config sets PIPELINE_BASE_BRANCH=main" "grep -qE '^PIPELINE_BASE_BRANCH=\"main\"[[:space:]]*' '$CFG'"
else
  echo "  SKIP: pipeline.config sets PIPELINE_BASE_BRANCH=main (file gitignored, not present)"
  SKIP=$((SKIP+1))
fi
assert "pipeline.config.example default is main" "grep -qE '^PIPELINE_BASE_BRANCH=\"main\"' '$EX'"
assert "README documents PIPELINE_BASE_BRANCH=\"main\" default" "grep -qE 'PIPELINE_BASE_BRANCH=\"main\"' '$README'"
assert "README no longer documents PIPELINE_BASE_BRANCH=\"staging\" as default" "! grep -qE 'PIPELINE_BASE_BRANCH=\"staging\"' '$README'"
assert "ci.yml on.push.branches drops staging" "! grep -qE '^[[:space:]]*branches:[[:space:]]*\[[[:space:]]*main[[:space:]]*,[[:space:]]*staging[[:space:]]*\]' '$CI'"
assert "ci.yml on.push.branches contains main" "grep -qE '^[[:space:]]*branches:[[:space:]]*\[[[:space:]]*main[[:space:]]*\]' '$CI'"

echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
