#!/usr/bin/env bash
# Real-vocabulary stage/issue normaliser guard (+ negative control + Finding-1).
#
# The normaliser maps the ACTUAL subagents.log task vocabulary (capitalized,
# lowercase-slug, and compound forms) to the canonical stages
# {classify, plan, plan-eval, execute, pr-eval}. We pin BOTH implementations
# and assert they normalise IDENTICALLY:
#   bash   : tu_stage_from_description / tu_issue_from_description
#            in scripts/_token-usage-lib.sh
#   python : stage_from_description / issue_from_description
#            in hooks/capture_agent_cost.py
#
# Issue-number expectations are pinned to the REAL producer behaviour (e.g. for
# "evaluate-issue-pr #626 / PR #637" the leading "#626" is the issue and the
# "/ PR #637" group is the PR), NOT an idealized spec.
#
# Also:
#   - NEGATIVE CONTROL: the idealized regex `^([a-z-]+)-issue #` would DROP the
#     dominant capitalized shapes; the new normaliser strictly supersedes it.
#   - FINDING-1: scripts/capture-agent-costs.sh resolves the fixture worktree to
#     the DOUBLE-dash slug dir (".claude" -> "--claude"), so the resolvable
#     headless run produces a record and the missing one is skipped.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures/token-usage"
LIB="$REPO_ROOT/scripts/_token-usage-lib.sh"
HOOK="$REPO_ROOT/hooks/capture_agent_cost.py"
RETRO_SRC="$REPO_ROOT/scripts/capture-agent-costs.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=../scripts/_token-usage-lib.sh
source "$LIB"

# Each row: TASK|EXPECTED_STAGE|EXPECTED_ISSUE  (empty stage+issue == skipped).
CASES=(
  "Classify #143|classify|143"
  "Classify issue #88|classify|88"
  "classify-issue #56|classify|56"
  "Plan #134|plan|134"
  "Plan issue #145|plan|145"
  "plan-issue #45|plan|45"
  "Re-plan #95|plan|95"
  "Evaluate plan #133|plan-eval|133"
  "Evaluate plan for #104|plan-eval|104"
  "evaluate-plan #46|plan-eval|46"
  "Re-evaluate plan #145|plan-eval|145"
  "Evaluate PR #137 for #134|pr-eval|134"
  "evaluate-issue-pr #626 / PR #637|pr-eval|626"
  "Evaluate PR #363 (#361)|pr-eval|361"
  "Evaluate PR #384 (issue #342)|pr-eval|342"
  "eval-pr #592 (PR #603)|pr-eval|592"
  "execute-issue-plan #45|execute|45"
  "Classify + plan + evaluate #107|classify|107"
  "analyze open-issue hygiene shortlist||"
  "audit interaction lens hourly digest||"
)

# Python combiner: prints "<stage>\t<issue>" using the REAL hook functions.
py_norm() {
  python3 - "$HOOK" "$1" <<'PY'
import importlib.util
import sys
hook_path, task = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("cac", hook_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
stage = m.stage_from_description(task)
issue = m.issue_from_description(task) if stage else ""
sys.stdout.write("%s\t%s" % (stage, issue))
PY
}

for row in "${CASES[@]}"; do
  task="${row%%|*}"
  rest="${row#*|}"
  exp_stage="${rest%%|*}"
  exp_issue="${rest#*|}"

  b_stage="$(tu_stage_from_description "$task")"
  if [ -n "$b_stage" ]; then
    b_issue="$(tu_issue_from_description "$task")"
  else
    b_issue=""
  fi

  p_out="$(py_norm "$task")"
  p_stage="${p_out%%$'\t'*}"
  p_issue="${p_out#*$'\t'}"

  if [ "$b_stage" = "$exp_stage" ] && [ "$b_issue" = "$exp_issue" ]; then
    pass_msg "bash   [$task] -> stage=$exp_stage issue=$exp_issue"
  else
    fail_msg "bash   [$task] -> stage=[$b_stage] issue=[$b_issue], want stage=[$exp_stage] issue=[$exp_issue]"
  fi

  if [ "$p_stage" = "$exp_stage" ] && [ "$p_issue" = "$exp_issue" ]; then
    pass_msg "python [$task] -> stage=$exp_stage issue=$exp_issue"
  else
    fail_msg "python [$task] -> stage=[$p_stage] issue=[$p_issue], want stage=[$exp_stage] issue=[$exp_issue]"
  fi

  if [ "$b_stage" = "$p_stage" ] && [ "$b_issue" = "$p_issue" ]; then
    pass_msg "lockstep [$task] bash == python"
  else
    fail_msg "lockstep drift [$task]: bash=[$b_stage,$b_issue] python=[$p_stage,$p_issue]"
  fi
done

# --- NEGATIVE CONTROL -----------------------------------------------------
# The idealized regex `^([a-z-]+)-issue #` drops the dominant capitalized
# shapes. Prove those lines do NOT match the old pattern yet DO get a stage
# from the new normaliser, i.e. the new normaliser strictly supersedes it.
OLD_PATTERN='^([a-z-]+)-issue #'
for task in "Classify #143" "Plan #134" "Evaluate PR #137 for #134"; do
  if printf '%s' "$task" | grep -qE "$OLD_PATTERN"; then
    fail_msg "negative control: old regex unexpectedly matched [$task]"
  else
    pass_msg "negative control: old regex drops [$task]"
  fi
  new_stage="$(tu_stage_from_description "$task")"
  if [ -n "$new_stage" ]; then
    pass_msg "negative control: new normaliser keeps [$task] -> $new_stage"
  else
    fail_msg "negative control: new normaliser dropped [$task]"
  fi
done

# --- FINDING-1: double-dash slug resolution -------------------------------
# capture-agent-costs.sh must resolve /home/fix/.../.claude/worktrees/wt-642 to
# the slug dir with ".claude" -> "--claude" (DOUBLE dash). The fixture
# transcript lives ONLY under that double-dash dir, so a working run emits a
# record for sess-aaaa-1111 and SKIPS the missing wt-999-missing transcript.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RHOME="$TMP/home"
RPROJ="$TMP/project"
mkdir -p "$RPROJ/.claude/logs"
cp "$FIX/runs.log" "$RPROJ/.claude/logs/runs.log"
cp "$FIX/subagents.log" "$RPROJ/.claude/logs/subagents.log"
cp -r "$FIX/subagents" "$RPROJ/.claude/logs/subagents"
SLUG=$(python3 -c 'import re,sys; print(re.sub(r"[/.]","-",sys.argv[1]))' \
  "/home/fix/claude-pipeline/.claude/worktrees/wt-642")
# Guard the precondition: the slug uses the double-dash form, not single-dash
# or a literal dot.
case "$SLUG" in
  *--claude-worktrees-wt-642)
    pass_msg "Finding-1: slug uses double-dash (.claude -> --claude): $SLUG" ;;
  *)
    fail_msg "Finding-1: slug not double-dash form: $SLUG" ;;
esac
mkdir -p "$RHOME/.claude/projects/$SLUG"
cp "$FIX/transcript.jsonl" "$RHOME/.claude/projects/$SLUG/sess-aaaa-1111.jsonl"

HOME="$RHOME" CLAUDE_PROJECT_DIR="$RPROJ" PIPELINE_LOGS_ENABLED=true \
  bash "$RETRO_SRC" >/dev/null 2>&1
OUT="$RPROJ/.claude/logs/agent-costs.jsonl"

if [ -s "$OUT" ]; then
  pass_msg "Finding-1: a record was produced from the double-dash slug fixture"
else
  fail_msg "Finding-1: no record produced from the double-dash slug fixture"
fi

# The resolvable headless run (sess-aaaa-1111) must be present; the missing one
# (sess-bbbb-2222 / wt-999-missing) must be skipped.
if grep -q '"session_id": "sess-aaaa-1111"' "$OUT" 2>/dev/null; then
  pass_msg "Finding-1: resolvable headless record present (sess-aaaa-1111)"
else
  fail_msg "Finding-1: resolvable headless record missing (sess-aaaa-1111)"
fi
if grep -q '"session_id": "sess-bbbb-2222"' "$OUT" 2>/dev/null; then
  fail_msg "Finding-1: unresolvable headless record must be skipped (sess-bbbb-2222)"
else
  pass_msg "Finding-1: unresolvable headless record skipped (sess-bbbb-2222)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
