# Step 0b — CI-fix mode

`skills/execute-issue-plan/SKILL.md` Step 0b points here. Read it when
`$PIPELINE_CI_FIX_CONTEXT` is non-empty; otherwise skip this file entirely and
start at Step 1.

**0b. CI-fix mode.** If `$PIPELINE_CI_FIX_CONTEXT` is non-empty, you were dispatched to fix a red CI run on an existing PR — not to implement a new plan. Skip steps 1–4 and step 9. Read the failure log at `$PIPELINE_CI_FIX_CONTEXT` and run `gh pr diff` to see the PR so far. Diagnose the failure, apply red→green→commit TDD discipline for the fix, run step 6 (Validate) once, then push the follow-up commit to the existing branch with `git push`. Do NOT call `gh pr create`. Do NOT change the `pr-open` label. Report the new commit SHA back to the orchestrator.
