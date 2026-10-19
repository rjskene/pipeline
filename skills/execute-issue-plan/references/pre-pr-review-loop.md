# Step 8 — pre-PR code review loop

**Knob.** When your dispatch prompt carries `PRE_PR_REVIEW=off` (emitted by
`scripts/resolve-execute-dispatch.sh`), skip Step 8 on every path and log
`PRE-PR-REVIEW: skipped reason=knob`. Direct invocation (no dispatch prompt)
reads `${PIPELINE_PRE_PR_REVIEW:-false}` — default off.

**PATH D early-return.** If labels contain `quick-fix`, skip Step 8 in its entirety (8a–8e) and go to Step 9: `evaluate-issue-pr` is D's sole review gate. `classify-issue` relies on this when applying `quick-fix`.

Otherwise Step 8 runs before `gh pr create`, while the branch is local-only:

| Step | Action |
|------|--------|
| 8a self-check | Against the plan comment: every `**Files to change:**` entry touched, every task deliverable present, `$PIPELINE_TEST_CMD` green, no unrelated diff. Fix gaps, re-run Step 6. |
| 8b reviewer | Dispatch the `Agent` below. Its description is FIXED text (the cost-attribution key); append nothing. It blocks until it returns — no poll loop. |
| 8c triage | Verify each finding against the code. **must-fix** (plan gap, test gap, real bug) → fix; **nice-to-have** → skip unless trivial; **incorrect** → reject with a one-line rationale in the commit message. PATH C impl fixes go through a fresh `tdd-implementer` dispatch (the delegation hook blocks direct edits); PATH B follows red→green→commit; PATH A edits directly. |
| 8d commit | One `fix(review): ...` commit per must-fix. |
| 8e re-validate | Re-run Step 6 once. |

```
Agent(
  subagent_type: "general-purpose",
  description: "code review #<N>",
  prompt: "<the plan comment body + git diff $PIPELINE_BASE_BRANCH...HEAD — flag plan-compliance gaps and real bugs; do not refactor>"
)
```
