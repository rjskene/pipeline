#!/bin/bash
# #1485 folded the classify stage into plan-issue. Pin the operator-facing
# docs to the new wording: plan-waves --stage=plan, classify inline in
# plan-issue, /pipeline:classify-issue standalone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
has()  { if grep -qF -- "$3" "$ROOT/$2"; then ok "$1"; else bad "$1"; fi; }
hasnt(){ if grep -qF -- "$3" "$ROOT/$2"; then bad "$1"; else ok "$1"; fi; }

has   "process-maps uses --stage=plan"              docs/process-maps.md "--stage=plan"
hasnt "process-maps drops --stage=classify"         docs/process-maps.md "--stage=classify"
has   "process-maps lifecycle says classify inline" docs/process-maps.md "classify inline"

ROW15=$(grep -F '[`/pipeline:classify-issue`]' "$ROOT/docs/skills-api.md" || true)
ROW16=$(grep -F '[`/pipeline:plan-issue`]' "$ROOT/docs/skills-api.md" || true)
if echo "$ROW15" | grep -qiF 'standalone'; then ok "skills-api classify-issue row says standalone"; else bad "skills-api classify-issue row says standalone"; fi
if echo "$ROW16" | grep -qiF 'classif'; then ok "skills-api plan-issue row mentions classification"; else bad "skills-api plan-issue row mentions classification"; fi

has   "cost-architecture cites #1485"               docs/cost-architecture.md "#1485"
has   "CLAUDE.md says classify runs inline"         CLAUDE.md "classify runs inline"
has   "README lifecycle strip intact"               README.md "create → classify → plan → eval → execute → eval-pr → merge"
hasnt "README transcript drops classify wave"       README.md "Wave 1: classify"
has   "campaign entry cites flow (a)→(d)"           skills/campaign/SKILL.md "(a)→(d)"
hasnt "campaign entry drops flow (a)→(e)"           skills/campaign/SKILL.md "(a)→(e)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
