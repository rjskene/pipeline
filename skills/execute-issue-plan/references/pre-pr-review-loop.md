# Step 8 — pre-PR code review loop

`skills/execute-issue-plan/SKILL.md` Step 8 points here. Read it before
`gh pr create` on PATH A, B and C. On PATH D (`quick-fix`) Step 8 is skipped in
its entirety and this file is not read — see the early-return contract below.

**PATH D early-return contract.** If labels contain `quick-fix` (PATH D), SKIP Step 8 in its entirety (8a–8e) and proceed to Step 9. What is skipped: the **pre-PR code review loop** — author self-check, independent reviewer dispatch, triage, fix commits, re-validate. Why: PATH D issues delegate review entirely to `evaluate-issue-pr` to keep the lane fast (one external review gate, not two). This is the contract `classify-issue` depends on when applying the `quick-fix` label — see `skills/classify-issue/SKILL.md` (PATH D row).

For all other paths, Step 8 runs BEFORE `gh pr create` to catch plan-compliance gaps and real bugs while the branch is still local-only.

**Step 8 owner — the role that opens the PR (#1225).** Step 8's `Agent(...)` dispatch requires tools a leaf executor does not have, so Step 8 is owned by the PR-opening role: on PATH A/B the inline execute `Agent` (`general-purpose`); on PATH C the ORCHESTRATOR, after every `tdd-implementer` leaf has returned and `path-c-split-worktree.sh reassemble` has run, and before `gh pr create` (Step 9). A `tdd-implementer` leaf NEVER runs Step 8; a leaf handed a Step 8-shaped task refuses loudly with `CAPABILITY-REFUSED:` per `agents/tdd-implementer.md` rather than substituting a self-review.

**8a. Author self-check.** Run this checklist inline against the plan comment body (from step 1): every `**Files to change:**` entry touched, every task deliverable present, `$PIPELINE_TEST_CMD` green, no unrelated diff. Fix any gaps and re-run step 6 before continuing.

**8b. Independent reviewer dispatch.** The description is FIXED text — the `capture-agent-costs.sh` attribution key (`stage=pr-eval role=review`); append nothing:
```
Agent(
  subagent_type: "general-purpose",
  description: "code review #<N>",
  prompt: "<the plan comment body + git diff $PIPELINE_BASE_BRANCH...HEAD — flag plan-compliance gaps and real bugs; do not refactor>"
)
```

Step 8's review flow is synchronous — the `Agent(...)` call blocks until it returns, so there is no poll loop to bound here. If a future revision adds background-task coordination, it MUST wait via `scripts/wait-for-sentinel.sh` (bounded timeout), never an inline `until grep ...; do sleep N; done` poll (see Constraints).

**8c. Triage findings.** Triage each finding yourself: verify the claim against the code before acting. Classify each as **must-fix** (plan-compliance gap, test gap, real bug → fix), **nice-to-have** (style, rename → skip unless trivial), or **incorrect** (reviewer misread → reject with a one-line rationale in the follow-up commit message).

Path-specific constraints when applying must-fixes:
- **PATH C (`multi-task`):** any must-fix touching impl code MUST go through a fresh inline `Agent(tdd-implementer)` dispatch (or a spawned worker under `--spawn`) — the `enforce-path-c-delegation` hook blocks direct orchestrator `Edit`/`Write` on impl files regardless of transport.
- **PATH B (standard):** must-fix code edits follow red→green→commit discipline.
- **PATH A (`docs-only`):** must-fix edits are direct.
- **PATH D (quick-fix):** step 8 is skipped entirely (see early-return contract above); this row only applies on forced re-entry.

**8d. Commit fixes.** Commit each must-fix as its own `fix(review): ...` commit (skip if zero must-fixes).

**8e. Re-validate.** Re-run step 6 once more to confirm the review fixes did not regress anything.

