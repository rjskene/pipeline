#!/usr/bin/env bash
set -uo pipefail
#
# #1445 — the preflight WIRING guard: skill prose + the hook interaction it
# changes.
#
# Two halves, because the change has two failure modes:
#
#  PROSE  — `skills/evaluate-issue-pr/SKILL.md` must trust the dispatched
#           `PREFLIGHT=ok` line instead of re-running the four mechanical
#           checks, and `skills/fullsend/SKILL.md` Step 7 must run the
#           preflight BEFORE any evaluator dispatch. Every assertion runs
#           against the skill BODY via tests/_lib/skill-body.sh — a whole-file
#           grep is satisfiable by the YAML `description:` line alone (#1218).
#
#  HOOK    — dropping the evaluator's own `gh pr view … --json
#           statusCheckRollup` read is a CORRECTNESS requirement, not a cost
#           tweak. `hooks/enforce-ci-wait.py` (ROLLUP_RE, L67) DENIES Stop
#           unless a rollup row is followed by a `gh pr checks … --watch` row,
#           and three denials escalate a `needs-human` label. With the
#           collapsed Step 5 no longer running `--watch` on the trusted path,
#           leaving the Step 4 rollup read in place would wedge EVERY eval.
#           The executable arm below proves the hook is out of scope when the
#           session's only preflight evidence is a `bash …/pr-eval-preflight.sh`
#           row, and the POSITIVE control proves the arm is not vacuous.
#
# No hook file is edited by #1445, so tests/test-cage-invariant-enforce-ci-wait.sh
# is unaffected; what changes is the hook's REACH, and that is what this test pins.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tests/_lib/skill-body.sh
source "$SCRIPT_DIR/_lib/skill-body.sh"

EVAL_SKILL="$ROOT/skills/evaluate-issue-pr/SKILL.md"
FULLSEND="$ROOT/skills/fullsend/SKILL.md"
PREFLIGHT="$ROOT/scripts/pr-eval-preflight.sh"
HOOK="$ROOT/hooks/enforce-ci-wait.py"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

for f in "$EVAL_SKILL" "$FULLSEND" "$HOOK"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

# body_has <file> <needle>  /  body_lacks <file> <needle>
want_body() {
  local file="$1" needle="$2" label="$3"
  if skill_body_has "$file" "$needle"; then
    pass_msg "$label"
  else
    fail_msg "$label (absent from the body: $needle)"
  fi
}
want_body_absent() {
  local file="$1" needle="$2" label="$3"
  if skill_body_has "$file" "$needle"; then
    fail_msg "$label (still present in the body: $needle)"
  else
    pass_msg "$label"
  fi
}

# --- region extractors (content-anchored, never line numbers) ---------------
eval_step4() {
  skill_body "$EVAL_SKILL" | awk '/^4\. \*\*Two-phase review/{f=1} /^<!-- BEGIN CI_CHECK -->/{f=0} f'
}
eval_ci_check() {
  skill_body "$EVAL_SKILL" | awk '/^<!-- BEGIN CI_CHECK -->/{f=1} /^<!-- END CI_CHECK -->/{f=0} f'
}
eval_step8() {
  skill_body "$EVAL_SKILL" | awk '/^8\. \*\*/{f=1} /^9\. \*\*/{f=0} f'
}

# ===========================================================================
# (a) the evaluator trusts the preflight line
# ===========================================================================
inc_scenario "(a) evaluate-issue-pr consumes the preflight contract"
want_body "$EVAL_SKILL" 'pr-eval-preflight.sh' \
  "the eval body names scripts/pr-eval-preflight.sh"
want_body "$EVAL_SKILL" 'PREFLIGHT=ok' \
  "the eval body carries a PREFLIGHT=ok trust clause"
want_body "$EVAL_SKILL" 'REASON=' \
  "the eval body reads the preflight REASON field"

# ===========================================================================
# (b) the aggregator call is GONE from the evaluator — the preflight owns it
# ===========================================================================
inc_scenario "(b) the Phase-2 aggregator call moved into the preflight"
want_body_absent "$EVAL_SKILL" 'check-cross-cutting-guards.sh' \
  "the eval body no longer invokes the cross-cutting aggregator directly"
if [ -f "$PREFLIGHT" ] && grep -qF 'check-cross-cutting-guards.sh' "$PREFLIGHT"; then
  pass_msg "scripts/pr-eval-preflight.sh invokes the aggregator (the ownership moved, it did not vanish)"
else
  fail_msg "scripts/pr-eval-preflight.sh does NOT reference check-cross-cutting-guards.sh — the guard was DROPPED, not relocated"
fi

# ===========================================================================
# (c) hook tripwire — no rollup command form outside the ci-pending branch
# ===========================================================================
inc_scenario "(c) the Step 4 rollup read is sourced from the preflight line"
S4="$(eval_step4)"
if [ -z "$S4" ]; then
  fail_msg "could not extract the Step 4 (Two-phase review) region"
elif printf '%s\n' "$S4" | grep -qE 'gh pr view .*--json statusCheckRollup'; then
  fail_msg "Step 4 STILL issues a 'gh pr view … --json statusCheckRollup' query — that single row wedges enforce-ci-wait.py on every trusted eval"
else
  pass_msg "Step 4 issues no statusCheckRollup query"
fi

CI_REGION="$(eval_ci_check)"
if [ -z "$CI_REGION" ]; then
  fail_msg "could not extract the <!-- BEGIN/END CI_CHECK --> region"
else
  pass_msg "the CI_CHECK marker region is still present (the region anchor survives the collapse)"
  ALL_ROLLUP="$(skill_body "$EVAL_SKILL" | grep -cE 'gh pr view .*--json statusCheckRollup' || true)"
  REGION_ROLLUP="$(printf '%s\n' "$CI_REGION" | grep -cE 'gh pr view .*--json statusCheckRollup' || true)"
  if [ "$ALL_ROLLUP" -ge 1 ] && [ "$ALL_ROLLUP" = "$REGION_ROLLUP" ]; then
    pass_msg "every rollup query in the body ($ALL_ROLLUP) lives inside the CI_CHECK region"
  else
    fail_msg "rollup queries in the body=$ALL_ROLLUP, inside CI_CHECK=$REGION_ROLLUP — they must be confined to the ci-pending / post-push branch"
  fi
fi

# ===========================================================================
# (d) regression anchors — the collapse must not drop a pinned literal
# ===========================================================================
inc_scenario "(d) the 8 test-evaluate-issue-pr-ci-trust.sh anchors survive the collapse"
for needle in 'statusCheckRollup' 'green rollup' 'PIPELINE_CI_CHECK_ENABLED' \
              'run tests locally' 'touched test' 'at most once' 'run_in_background'; do
  want_body "$EVAL_SKILL" "$needle" "ci-trust anchor present: $needle"
done
if skill_body "$EVAL_SKILL" | grep -qE 'skip(ping)? (the )?full.*PIPELINE_TEST_CMD'; then
  pass_msg "ci-trust anchor present: skip-full-PIPELINE_TEST_CMD-re-run directive"
else
  fail_msg "ci-trust anchor MISSING: skip-full-PIPELINE_TEST_CMD-re-run directive"
fi
if skill_body "$EVAL_SKILL" | grep -qE 'timeout 600 gh pr checks .*--watch --fail-fast --interval 30'; then
  pass_msg "the bounded foreground --watch command survives (test-evaluate-pr-auto-merge-prose.sh anchor)"
else
  fail_msg "the 'timeout 600 gh pr checks … --watch --fail-fast --interval 30' anchor was dropped"
fi
if skill_body "$EVAL_SKILL" | grep -qE 'run_in_background:?[[:space:]]*true'; then
  fail_msg "the body now instructs run_in_background:true (#684 ban)"
else
  pass_msg "no run_in_background:true in the body (#684 ban holds)"
fi

# ===========================================================================
# (i) the preflight line is STALE after a Step 7 fix push (binding amendment)
# ===========================================================================
inc_scenario "(i) a Step 7 fix push re-arms the full rollup -> watch -> rollup triple"
# The collapse deletes today's only post-fix re-watch instruction (old Step
# 5d). A `git push` invalidates the preflight line, and on that one path the
# hook's teeth are the only thing standing between an Approved verdict and a
# red head — so the triple must be re-emitted there.
want_body "$EVAL_SKILL" 'git push' \
  "the collapsed Step 5 names the invalidating event (git push)"
if printf '%s\n' "$CI_REGION" | grep -qiE 'stale|invalidat|re-?(emit|arm|read|watch|run)'; then
  pass_msg "the CI_CHECK region states the preflight line goes stale on a push and the triple is re-emitted"
else
  fail_msg "the CI_CHECK region carries no post-push re-watch instruction — old Step 5d was deleted without a replacement"
fi

# ===========================================================================
# (j) Step 8 reads mergeability ITSELF (binding amendment)
# ===========================================================================
inc_scenario "(j) Step 8 does not key the rebase off REASON=mergeable"
# REASON carries exactly ONE advisory. Whenever `ci-pending` wins the ordering
# the `mergeable` advisory is LOST, so a Step 8 keyed off `REASON=mergeable`
# would never fire and the PR would strand on auto-merge-gate's
# `block-mergeable` — the exact failure the advisory-not-block deviation
# exists to prevent. That query is not a statusCheckRollup query, so ROLLUP_RE
# never matches it and the hook stays out of scope.
S8="$(eval_step8)"
if [ -z "$S8" ]; then
  fail_msg "could not extract the Step 8 (rebase) region"
elif printf '%s\n' "$S8" | grep -qF -- '--json mergeable,mergeStateStatus'; then
  pass_msg "Step 8 still reads 'gh pr view … --json mergeable,mergeStateStatus' itself"
else
  fail_msg "Step 8 no longer reads mergeability directly — a lost 'mergeable' advisory would strand the PR"
fi
if printf '%s\n' "$S8" | grep -qE 'gh pr view .*--json statusCheckRollup'; then
  fail_msg "Step 8's mergeability query must not be widened to statusCheckRollup (it would re-arm ROLLUP_RE outside the ci-pending branch)"
else
  pass_msg "Step 8's query does not match the hook's ROLLUP_RE"
fi

# ===========================================================================
# (e) EXECUTABLE hook-interaction arm + positive control
# ===========================================================================
inc_scenario "(e) enforce-ci-wait.py is out of scope for a preflight-trusting eval"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/proj"
mkdir -p "$PROJ/.claude/logs" "$WORK/bin"
printf 'PIPELINE_REPO="fake/repo"\n' > "$PROJ/pipeline.config"

# gh stub: the hook asks for the rollup LENGTH and the FAILURE/CANCELLED count.
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"[.statusCheckRollup"*) printf '%s' "${STUB_GH_FAIL_COUNT:-0}" ;;
  *". | length"*)          printf '%s' "${STUB_GH_ROLLUP_LEN:-1}" ;;
  *)                       printf '%s' "" ;;
esac
STUB
chmod +x "$WORK/bin/gh"

seed_row() {
  printf '%s\tpost\tBash\tsession=%s\t%s\n' "$1" "$2" "$3" \
    >> "$PROJ/.claude/logs/tool-use.log"
}

run_hook() {
  local sid="$1"
  ( cd "$PROJ" && printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$PROJ" | env -i \
      HOME="$HOME" PATH="$WORK/bin:/usr/bin:/bin" \
      CLAUDE_PROJECT_DIR="$PROJ" \
      PIPELINE_LOGS_ENABLED=false \
      CLAUDE_PIPELINE_SKILL=evaluate-issue-pr \
      STUB_GH_ROLLUP_LEN=1 STUB_GH_FAIL_COUNT="${WANT_FAILED:-0}" \
      python3 "$HOOK" >"$WORK/out.txt" 2>"$WORK/err.txt" )
  echo "$?"
}

# Trusted path: the session's only preflight evidence is the SCRIPT call, and
# the eval posted an Approved verdict on a head with 2 FAILURE checks.
rm -f "$PROJ/.claude/logs/tool-use.log"
seed_row "2026-10-03T10:00:00Z" "sess-pf" "bash /plugin/scripts/pr-eval-preflight.sh 1445 --pr 123 --worktree /wt"
seed_row "2026-10-03T10:01:00Z" "sess-pf" "gh pr diff 123 --repo fake/repo"
seed_row "2026-10-03T10:02:00Z" "sess-pf" "gh pr comment 123 --repo fake/repo --body '## Evaluation Approved'"
WANT_FAILED=2 RC_TRUSTED="$(WANT_FAILED=2 run_hook sess-pf)"
if [ "$RC_TRUSTED" = "0" ]; then
  pass_msg "no rollup row in the session -> hook exits 0 (out of scope by construction)"
else
  fail_msg "hook exited $RC_TRUSTED on a preflight-only session (expected 0); stderr: $(cat "$WORK/err.txt")"
fi
if grep -qE 'pr-eval-preflight\.sh' "$PROJ/.claude/logs/tool-use.log"; then
  pass_msg "the seeded session really does record a pr-eval-preflight.sh Bash row"
else
  fail_msg "fixture bug: no pr-eval-preflight.sh row was seeded"
fi

# POSITIVE CONTROL — identical fixture, the preflight row REPLACED by the
# Step-4-shaped rollup query. Exactly one property differs. The hook must now
# DENY, which is what makes the assertion above non-vacuous.
rm -f "$PROJ/.claude/logs/tool-use.log"
rm -rf "$PROJ/.claude/logs/enforce-ci-wait-state"
seed_row "2026-10-03T10:00:00Z" "sess-rollup" "gh pr view 123 --repo fake/repo --json statusCheckRollup"
seed_row "2026-10-03T10:01:00Z" "sess-rollup" "gh pr diff 123 --repo fake/repo"
seed_row "2026-10-03T10:02:00Z" "sess-rollup" "gh pr comment 123 --repo fake/repo --body '## Evaluation Approved'"
RC_CONTROL="$(WANT_FAILED=2 run_hook sess-rollup)"
if [ "$RC_CONTROL" = "2" ] && grep -q 'CI-wait gate' "$WORK/err.txt"; then
  pass_msg "negative control: a Step-4-shaped rollup row with no --watch -> hook exits 2 (the wedge is real)"
else
  fail_msg "negative control did NOT block (rc=$RC_CONTROL) — this test cannot prove the hook interaction; stderr: $(cat "$WORK/err.txt")"
fi

# ===========================================================================
# (f) fullsend Step 7 — the ORDER rule
# ===========================================================================
inc_scenario "(f) fullsend Step 7 runs the preflight BEFORE any evaluator dispatch"
PREFLIGHT_DOC="$ROOT/skills/fullsend/references/pr-eval-preflight.md"
step7_window() {
  skill_body "$FULLSEND" | awk '/^7\. \*\*Evaluate PRs \(wave N\)/{f=1} /^7b\. /{f=0} f'
}
S7="$(step7_window | tr '\n' ' ')"
if [ -z "$S7" ]; then
  fail_msg "could not extract the fullsend Step 7 (Evaluate PRs) window"
else
  pass_msg "the fullsend Step 7 window is extractable"
  case "$S7" in
    *pr-eval-preflight.sh*) pass_msg "Step 7 invokes scripts/pr-eval-preflight.sh" ;;
    *) fail_msg "Step 7 does not invoke scripts/pr-eval-preflight.sh" ;;
  esac
  # Byte-offset comparison inside the window: the preflight must be named
  # BEFORE the evaluator dispatch, because "run them both" without an order is
  # exactly the wiring that spends an Opus eval on a PR the preflight blocks.
  if case "$S7" in *preflight*) true ;; *) false ;; esac \
     && case "$S7" in *"/pipeline:evaluate-issue-pr"*) true ;; *) false ;; esac; then
    _pre="${S7%%preflight*}"
    _dis="${S7%%/pipeline:evaluate-issue-pr*}"
    if [ "${#_pre}" -lt "${#_dis}" ]; then
      pass_msg "the preflight (offset ${#_pre}) precedes the evaluator dispatch (offset ${#_dis}) in Step 7"
    else
      fail_msg "the evaluator dispatch (offset ${#_dis}) precedes the preflight (offset ${#_pre}) — the order rule is inverted"
    fi
  else
    fail_msg "Step 7 does not mention both the preflight and the /pipeline:evaluate-issue-pr dispatch"
  fi
  case "$S7" in
    *PREFLIGHT=ok*) pass_msg "Step 7 gates the dispatch on PREFLIGHT=ok" ;;
    *) fail_msg "Step 7 does not name the PREFLIGHT=ok gate condition" ;;
  esac
fi

# ===========================================================================
# (g) the --spawn rule, and that run-queue.sh is NOT modified
# ===========================================================================
inc_scenario "(g) the --spawn gate is orchestrator-side; run-queue.sh is unchanged"
# Hot-path mass: skills/fullsend/SKILL.md is ceiling-bound
# (tests/test-skill-hot-path-mass.sh), so the long-form rationale lives in
# references/pr-eval-preflight.md, read when the `--spawn` trigger fires. The
# POINTER must be inline, and the rule must be written down somewhere.
case "$S7" in
  *references/pr-eval-preflight.md*) pass_msg "Step 7 points at references/pr-eval-preflight.md" ;;
  *) fail_msg "Step 7 carries no pointer to references/pr-eval-preflight.md" ;;
esac
if [ ! -f "$PREFLIGHT_DOC" ]; then
  fail_msg "skills/fullsend/references/pr-eval-preflight.md does not exist"
else
  pass_msg "skills/fullsend/references/pr-eval-preflight.md exists"
  for needle in 'run-queue.sh' '--skill evaluate-issue-pr' 'PREFLIGHT=ok'; do
    if grep -qF -- "$needle" "$PREFLIGHT_DOC"; then
      pass_msg "the reference states the --spawn rule: $needle"
    else
      fail_msg "the reference does not mention $needle"
    fi
  done
  if grep -qE 'run-queue\.sh.{0,60}(NOT|not) (modified|changed)|(NOT|not) (modified|changed).{0,60}run-queue\.sh' "$PREFLIGHT_DOC"; then
    pass_msg "the reference records that run-queue.sh is NOT modified (no per-issue prompt channel)"
  else
    fail_msg "the reference does not record that run-queue.sh is unmodified"
  fi
fi
# Executable half of the same claim: run-queue.sh really does carry no
# per-issue prompt channel, which is WHY the gate cannot live in the queue.
# (The pattern deliberately names no PIPELINE_* knob — a knob name mentioned
# anywhere under tests/ is a check-config-drift.sh UNDOCUMENTED finding.)
if grep -qE -- '--prompt|--append-prompt' "$ROOT/scripts/run-queue.sh"; then
  fail_msg "scripts/run-queue.sh now exposes a per-issue prompt channel — the orchestrator-side gate rationale needs revisiting"
else
  pass_msg "scripts/run-queue.sh exposes no per-issue prompt channel (the gate must precede the queue launch)"
fi

# ===========================================================================
# (h) the Step 7 prompt contract no longer orders a Phase-2 aggregator re-run
# ===========================================================================
inc_scenario "(h) the Step 7 prompt contract stops ordering the aggregator re-run"
case "$S7" in
  *check-cross-cutting-guards.sh*)
    fail_msg "the Step 7 prompt contract still directs the evaluator to run check-cross-cutting-guards.sh in Phase 2 (the preflight owns it now)" ;;
  *)
    pass_msg "the Step 7 prompt contract no longer orders a Phase-2 aggregator re-run" ;;
esac
# Non-vacuity: the aggregator directive must still exist elsewhere in fullsend
# (the Step 6 execute dispatch contract), so this is a RELOCATION, not a drop.
if skill_body_has "$FULLSEND" 'check-cross-cutting-guards.sh'; then
  pass_msg "fullsend still carries the aggregator directive outside Step 7 (execute dispatch contract)"
else
  fail_msg "fullsend no longer mentions check-cross-cutting-guards.sh at all — the execute-side directive was dropped"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
